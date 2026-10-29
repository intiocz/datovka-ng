//! Import of messages from the mobile Datovka app.
//!
//! The mobile app hands its data over as a "transfer" ZIP (backup JSON with
//! `appVariant = "mobile"`); once unpacked, the folder holds:
//!
//! * per-account message databases `{username}___{0|1}.db` (the digit is the
//!   test-environment flag) using the same schema as the desktop databases
//!   (`messages`, `supplementary_message_data`, `raw_message_data`, ...);
//! * optionally an accompanying directory `{username}___{0|1}/{dmID}/` holding
//!   messages stored as files: `DDZ_{dmID}.zfo` (received), `ODZ_{dmID}.zfo`
//!   (sent), `DD_{dmID}.zfo` (delivery info) and `ATT_*` attachments;
//! * optionally the legacy `zfo.db` with table
//!   `message_zfos(dmID, testEnv, data)` holding base64 ZFOs.
//!
//! The direction is `supplementary_message_data.message_type` (1 received,
//! 2 sent), the read state `supplementary_message_data.read_locally`, and the
//! signed message the base64 `raw_message_data.data`.

use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use super::lock::WriteLock;
use super::{column_bytes, decode_stored, LegacyAccount, LegacyStore};
use crate::error::{Error, Result};
use crate::model::Direction;

const ZFO_DB_NAME: &str = "zfo.db";

/// A message database found in a folder with mobile app data.
#[derive(Debug, Clone, Serialize)]
pub struct MobileAccountDb {
    pub username: String,
    pub test_env: bool,
    pub path: PathBuf,
    /// Number of messages in the database.
    pub messages: i64,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ImportReport {
    /// Messages found in the mobile database.
    pub total: usize,
    /// Messages newly stored in the desktop databases.
    pub imported: usize,
    /// Messages already present in the desktop databases (left untouched).
    pub already_present: usize,
    /// Messages without a complete signed message (ZFO); cannot be imported.
    pub missing_zfo: Vec<i64>,
    /// Messages whose import failed, with the reason.
    pub failed: Vec<(i64, String)>,
}

/// Splits a mobile database file name `{username}[_{year}]___{0|1}.db`.
fn parse_db_name(name: &str) -> Option<(String, bool)> {
    let stem = name.strip_suffix(".db")?;
    let (prefix, flag) = stem.rsplit_once("___")?;
    let test_env = match flag {
        "0" => false,
        "1" => true,
        _ => return None,
    };
    let username = match prefix.split_once('_') {
        Some((user, year))
            if year == "inv" || (year.len() == 4 && year.bytes().all(|b| b.is_ascii_digit())) =>
        {
            user
        }
        Some(_) => return None,
        None => prefix,
    };
    if username.is_empty() || !username.chars().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    Some((username.to_string(), test_env))
}

fn table_exists(c: &Connection, table: &str) -> Result<bool> {
    Ok(c.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table],
        |r| r.get::<_, i64>(0),
    )? > 0)
}

/// Finds mobile message databases in `dir` and its direct subdirectories
/// (an unpacked ZIP may keep its content in a base folder).
pub fn scan(dir: &Path) -> Result<Vec<MobileAccountDb>> {
    let mut found = Vec::new();
    let mut dirs = vec![dir.to_path_buf()];
    for e in std::fs::read_dir(dir)?.filter_map(|e| e.ok()) {
        let p = e.path();
        let accompanying = p
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.contains("___"));
        if p.is_dir() && !accompanying {
            dirs.push(p);
        }
    }
    for d in dirs {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in entries.filter_map(|e| e.ok()) {
            let path = e.path();
            let Some((username, test_env)) = path
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(parse_db_name)
            else {
                continue;
            };
            if !path.is_file() {
                continue;
            }
            let Ok(c) = LegacyStore::open_ro(&path) else {
                continue;
            };
            if !table_exists(&c, "messages").unwrap_or(false) {
                continue;
            }
            let messages = c
                .query_row("SELECT COUNT(*) FROM messages", [], |r| r.get(0))
                .unwrap_or(0);
            found.push(MobileAccountDb {
                username,
                test_env,
                path,
                messages,
            });
        }
    }
    found.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(found)
}

struct MobileMessage {
    dm_id: i64,
    direction: Direction,
    read_locally: Option<bool>,
}

/// Reads the mobile database and the files around it.
struct MobileSource {
    conn: Connection,
    has_supp: bool,
    has_raw: bool,
    has_raw_di: bool,
    /// Accompanying directory with messages stored as files.
    assoc_dir: PathBuf,
    zfo_db: Option<Connection>,
    test_env: bool,
}

impl MobileSource {
    fn open(db: &Path, test_env: bool) -> Result<Self> {
        let conn = LegacyStore::open_ro(db)?;
        let has_supp = table_exists(&conn, "supplementary_message_data")?;
        let has_raw = table_exists(&conn, "raw_message_data")?;
        let has_raw_di = table_exists(&conn, "raw_delivery_info_data")?;
        let assoc_dir = db.with_extension("");
        let zfo_db = db
            .parent()
            .map(|p| p.join(ZFO_DB_NAME))
            .filter(|p| p.is_file())
            .and_then(|p| LegacyStore::open_ro(&p).ok())
            .filter(|c| table_exists(c, "message_zfos").unwrap_or(false));
        Ok(Self {
            conn,
            has_supp,
            has_raw,
            has_raw_di,
            assoc_dir,
            zfo_db,
            test_env,
        })
    }

    fn messages(&self) -> Result<Vec<MobileMessage>> {
        let sql = if self.has_supp {
            "SELECT m.dmID, s.message_type, s.read_locally FROM messages m
             LEFT JOIN supplementary_message_data s ON s.message_id = m.dmID ORDER BY m.dmID"
        } else {
            "SELECT dmID, NULL, NULL FROM messages ORDER BY dmID"
        };
        let mut stmt = self.conn.prepare(sql)?;
        let rows = stmt.query_map([], |r| {
            Ok(MobileMessage {
                dm_id: r.get(0)?,
                direction: if r.get::<_, Option<i64>>(1)? == Some(2) {
                    Direction::Sent
                } else {
                    Direction::Received
                },
                read_locally: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    fn blob(&self, table: &str, dm_id: i64) -> Option<Vec<u8>> {
        let data = self
            .conn
            .query_row(
                &format!("SELECT data FROM {table} WHERE message_id = ?1"),
                [dm_id],
                |r| column_bytes(r, 0),
            )
            .optional()
            .ok()???;
        decode_stored(&data).ok().filter(|d| !d.is_empty())
    }

    fn file(&self, dm_id: i64, name: &str) -> Option<Vec<u8>> {
        std::fs::read(self.assoc_dir.join(dm_id.to_string()).join(name))
            .ok()
            .filter(|d| !d.is_empty())
    }

    /// Signed message: database, then a file next to it, then `zfo.db`.
    fn zfo(&self, m: &MobileMessage) -> Option<Vec<u8>> {
        let id = m.dm_id;
        if self.has_raw {
            if let Some(d) = self.blob("raw_message_data", id) {
                return Some(d);
            }
        }
        let primary = match m.direction {
            Direction::Received => format!("DDZ_{id}.zfo"),
            Direction::Sent => format!("ODZ_{id}.zfo"),
        };
        for name in [primary, format!("DZ_{id}.zfo")] {
            if let Some(d) = self.file(id, &name) {
                return Some(d);
            }
        }
        let c = self.zfo_db.as_ref()?;
        let data = c
            .query_row(
                "SELECT data FROM message_zfos WHERE dmID = ?1 AND testEnv = ?2",
                params![id, self.test_env],
                |r| column_bytes(r, 0),
            )
            .optional()
            .ok()???;
        decode_stored(&data).ok().filter(|d| !d.is_empty())
    }

    fn delivery_zfo(&self, dm_id: i64) -> Option<Vec<u8>> {
        if self.has_raw_di {
            if let Some(d) = self.blob("raw_delivery_info_data", dm_id) {
                return Some(d);
            }
        }
        self.file(dm_id, &format!("DD_{dm_id}.zfo"))
    }
}

impl LegacyStore {
    /// Imports messages of a mobile message database (see [`scan`]) into the
    /// desktop databases of `account`. Messages already present are skipped;
    /// the local read state is carried over for newly imported ones.
    pub fn import_mobile(
        &self,
        lock: &WriteLock,
        account: &LegacyAccount,
        db: &Path,
    ) -> Result<ImportReport> {
        let name = db.file_name().and_then(|n| n.to_str()).unwrap_or_default();
        let (username, test_env) = parse_db_name(name).ok_or_else(|| Error::Isds {
            code: "mobile".into(),
            text: format!("soubor {name} není databáze zpráv mobilní Datovky"),
        })?;
        if username != account.username || test_env != account.test_env {
            return Err(Error::Isds {
                code: "mobile".into(),
                text: format!(
                    "databáze {name} patří účtu {username}, ne účtu {}",
                    account.username
                ),
            });
        }
        let src = MobileSource::open(db, test_env)?;
        let mut report = ImportReport::default();
        for m in src.messages()? {
            report.total += 1;
            if self.contains(account, m.dm_id)? {
                report.already_present += 1;
                continue;
            }
            let Some(zfo) = src.zfo(&m) else {
                report.missing_zfo.push(m.dm_id);
                continue;
            };
            let di = src.delivery_zfo(m.dm_id);
            match self.insert_message(lock, account, m.direction, &zfo, di.as_deref()) {
                Ok(true) => {
                    report.imported += 1;
                    if let Some(read) = m.read_locally {
                        self.set_read_locally(lock, account, m.dm_id, read)?;
                    }
                }
                Ok(false) => report.already_present += 1,
                Err(e) => report.failed.push((m.dm_id, e.to_string())),
            }
        }
        Ok(report)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::legacy::lock;
    use base64::Engine;

    const SAMPLE: &str = "../reference/datovka-qt/tests/data/DZ_6452235.zfo";
    const DM_ID: i64 = 6452235;

    #[test]
    fn parses_db_names() {
        assert_eq!(
            parse_db_name("abc123___0.db"),
            Some(("abc123".into(), false))
        );
        assert_eq!(
            parse_db_name("abc123___1.db"),
            Some(("abc123".into(), true))
        );
        assert_eq!(
            parse_db_name("abc123_2018___1.db"),
            Some(("abc123".into(), true))
        );
        assert_eq!(parse_db_name("zfo.db"), None);
        assert_eq!(parse_db_name("abc___2.db"), None);
        assert_eq!(parse_db_name("messages.shelf.db"), None);
    }

    fn mobile_db(path: &Path, rows: &[(i64, i64, bool, Option<&[u8]>)]) {
        let c = Connection::open(path).unwrap();
        c.execute_batch(include_str!("schema.sql")).unwrap();
        for (id, ty, read, zfo) in rows {
            c.execute("INSERT INTO messages (dmID) VALUES (?1)", [id])
                .unwrap();
            c.execute(
                "INSERT INTO supplementary_message_data (message_id, message_type, read_locally)
                 VALUES (?1, ?2, ?3)",
                params![id, ty, read],
            )
            .unwrap();
            if let Some(z) = zfo {
                let b64 = base64::engine::general_purpose::STANDARD.encode(z);
                c.execute(
                    "INSERT INTO raw_message_data (message_id, message_type, data)
                     VALUES (?1, ?2, ?3)",
                    params![id, ty, b64.into_bytes()],
                )
                .unwrap();
            }
        }
    }

    #[test]
    fn imports_mobile_database() {
        let Ok(zfo) = std::fs::read(SAMPLE) else {
            return; // reference data not present
        };
        let root = std::env::temp_dir().join(format!("datovka-mobile-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let store_dir = root.join("dsgui");
        let mobile_dir = root.join("mobile");
        std::fs::create_dir_all(&store_dir).unwrap();
        std::fs::create_dir_all(mobile_dir.join("backup")).unwrap();

        // Desktop store with a template database.
        let tpl = Connection::open(store_dir.join("tpl_2000___0.db")).unwrap();
        tpl.execute_batch(include_str!("schema.sql")).unwrap();
        drop(tpl);
        std::fs::write(
            store_dir.join("dsgui.conf"),
            "[credentials]\nname=T\nusername=abc\n",
        )
        .unwrap();

        // Mobile data: the sample marked as read plus a message without ZFO.
        let db = mobile_dir.join("backup").join("abc___0.db");
        mobile_db(&db, &[(DM_ID, 1, true, Some(&zfo)), (42, 1, false, None)]);
        std::fs::write(mobile_dir.join("backup").join("zfo.db"), b"").unwrap();
        mobile_db(&mobile_dir.join("other___1.db"), &[]);

        let found = scan(&mobile_dir).unwrap();
        assert_eq!(found.len(), 2);
        let acc_db = found.iter().find(|f| f.username == "abc").unwrap();
        assert!(!acc_db.test_env);
        assert_eq!(acc_db.messages, 2);
        assert_eq!(acc_db.path, db);
        assert!(found.iter().any(|f| f.username == "other" && f.test_env));

        let store = LegacyStore::new(&store_dir);
        let acc = store.account("abc").unwrap();
        let lock::Acquire::Acquired(l) = lock::acquire(&store_dir, "test").unwrap() else {
            panic!()
        };
        let r = store.import_mobile(&l, &acc, &db).unwrap();
        assert_eq!(r.total, 2);
        assert_eq!(r.imported, 1);
        assert_eq!(r.already_present, 0);
        assert_eq!(r.missing_zfo, vec![42]);
        assert!(r.failed.is_empty());

        let msgs = store.messages(&acc).unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].dm_id, DM_ID);
        assert!(msgs[0].read_locally);
        assert_eq!(store.zfo(&acc, DM_ID).unwrap().unwrap(), zfo);

        // Second run skips the stored message.
        let r = store.import_mobile(&l, &acc, &db).unwrap();
        assert_eq!((r.imported, r.already_present), (0, 1));

        // Wrong account is refused.
        assert!(store
            .import_mobile(&l, &acc, &mobile_dir.join("other___1.db"))
            .is_err());

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn reads_zfo_from_accompanying_directory() {
        let Ok(zfo) = std::fs::read(SAMPLE) else {
            return;
        };
        let root =
            std::env::temp_dir().join(format!("datovka-mobile-files-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(format!("abc___0/{DM_ID}"))).unwrap();
        let db = root.join("abc___0.db");
        mobile_db(&db, &[(DM_ID, 2, false, None)]);
        std::fs::write(root.join(format!("abc___0/{DM_ID}/ODZ_{DM_ID}.zfo")), &zfo).unwrap();
        let src = MobileSource::open(&db, false).unwrap();
        let msgs = src.messages().unwrap();
        assert_eq!(msgs[0].direction, Direction::Sent);
        assert_eq!(src.zfo(&msgs[0]).unwrap(), zfo);
        assert!(src.delivery_zfo(DM_ID).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }
}
