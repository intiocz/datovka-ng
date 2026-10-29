//! Data of the original Datovka (`~/.dsgui`): `dsgui.conf`, `messages.shelf.db`
//! and per-account message databases `{user}[_{year}]___{0|1}.db`.
//!
//! Both applications share these files, so everything here keeps the original
//! schema and journal mode untouched. Connections are opened per operation and
//! closed right after, so a synced folder (iCloud Drive) always sees complete files.

pub mod backup;
pub mod conf;
mod extra;
mod flags;
pub mod lock;
pub mod mobile;
pub mod pin;
pub mod query;
pub mod sealed;
pub mod stamps;
pub mod secrets;
pub mod sync;
mod write;

use std::path::{Path, PathBuf};

use base64::Engine;
use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde::Serialize;

use crate::envelope::parse_time;
use crate::error::{Error, Result};
use crate::model::Direction;
pub use conf::{public_account, LegacyAccount};
pub use extra::{Draft, MessageMark, Tag};

#[derive(Debug, Clone, Default, Serialize)]
pub struct BoxInfo {
    pub username: String,
    pub box_id: Option<String>,
    pub box_type: Option<String>,
    pub owner: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MessageSummary {
    pub username: String,
    pub dm_id: i64,
    pub direction: Direction,
    pub annotation: Option<String>,
    pub sender: Option<String>,
    pub sender_address: Option<String>,
    pub sender_box_id: Option<String>,
    pub recipient: Option<String>,
    pub recipient_address: Option<String>,
    pub recipient_box_id: Option<String>,
    pub sender_ref_number: Option<String>,
    pub recipient_ref_number: Option<String>,
    pub delivery_time: Option<DateTime<Utc>>,
    pub acceptance_time: Option<DateTime<Utc>>,
    pub status: Option<i64>,
    pub attachments: Option<i64>,
    pub read_locally: bool,
    pub has_zfo: bool,
    /// 0 unsettled, 1 in progress, 2 settled (`process_state` of the original).
    pub process_state: i64,
    /// ISDS marked the message as suspicious (`specMessFlag`).
    pub suspicious: bool,
    /// Database file the message lives in (file name only).
    pub db_file: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AttachmentInfo {
    pub id: i64,
    pub file_name: String,
    pub mime_type: Option<String>,
    pub size: Option<i64>,
}

pub struct LegacyStore {
    dir: PathBuf,
}

const COLUMNS: &str = "m.dmID, s.message_type, m.dmAnnotation, m.dmSender, m.dmSenderAddress,
    m.dbIDSender, m.dmRecipient, m.dmRecipientAddress, m.dbIDRecipient, m.dmSenderRefNumber,
    m.dmRecipientRefNumber, m.dmDeliveryTime, m.dmAcceptanceTime, m.dmMessageStatus,
    s.attsNum, s.read_locally, (SELECT COUNT(*) FROM raw_message_data r WHERE r.message_id = m.dmID)";

impl LegacyStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// Default location `~/.dsgui`.
    pub fn default_dir() -> Option<PathBuf> {
        std::env::var_os("HOME")
            .or_else(|| std::env::var_os("USERPROFILE"))
            .map(|h| PathBuf::from(h).join(".dsgui"))
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Accounts of `dsgui.conf`. A password the original app did not store
    /// there comes from the system password store of this device.
    pub fn accounts(&self) -> Result<Vec<LegacyAccount>> {
        let mut accs = conf::load(&self.dir)?;
        for a in &mut accs {
            if a.password.is_none() && !a.pin_protected {
                a.password = secrets::password(&a.username, a.test_env);
            }
        }
        Ok(accs)
    }

    pub fn account(&self, username: &str) -> Result<LegacyAccount> {
        self.accounts()?
            .into_iter()
            .find(|a| a.username == username)
            .ok_or_else(|| Error::Isds {
                code: "account".into(),
                text: format!("účet {username} není v dsgui.conf"),
            })
    }

    fn open_ro(path: &Path) -> Result<Connection> {
        upgrade_message_db(path);
        Ok(Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?)
    }

    fn open_create(path: &Path) -> Result<Connection> {
        let c = Connection::open(path)?;
        c.busy_timeout(std::time::Duration::from_secs(5))?;
        Ok(c)
    }

    fn open_rw(path: &Path) -> Result<Connection> {
        upgrade_message_db(path);
        let c = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        c.busy_timeout(std::time::Duration::from_secs(5))?;
        Ok(c)
    }

    /// Box details stored by the original app in `messages.shelf.db`.
    pub fn box_info(&self, account: &LegacyAccount) -> Result<BoxInfo> {
        let mut info = BoxInfo {
            username: account.username.clone(),
            ..Default::default()
        };
        let path = self.dir.join("messages.shelf.db");
        if !path.exists() {
            return Ok(info);
        }
        let c = Self::open_ro(&path)?;
        let key = format!(
            "{}___{}",
            account.username,
            if account.test_env { "False" } else { "True" }
        );
        let row = c
            .query_row(
                "SELECT dbID, dbType, firmName, pnFirstName, pnLastName
                 FROM account_info WHERE key = ?1",
                params![key],
                |r| {
                    Ok((
                        r.get::<_, Option<String>>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, Option<String>>(2)?,
                        r.get::<_, Option<String>>(3)?,
                        r.get::<_, Option<String>>(4)?,
                    ))
                },
            )
            .optional()?;
        if let Some((id, ty, firm, first, last)) = row {
            info.box_id = id;
            info.box_type = ty;
            let person = [first, last]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" ");
            info.owner = firm
                .filter(|f| !f.is_empty())
                .or_else(|| (!person.is_empty()).then_some(person));
        }
        Ok(info)
    }

    /// Folder with the message databases of an account: `database_dir` of
    /// `dsgui.conf` when the original app was told to keep them elsewhere,
    /// otherwise the archive folder. A relative path counts from the archive.
    /// The archive is shared between computers, so a folder that does not
    /// exist on this one falls back to the archive folder too.
    pub fn db_dir(&self, account: &LegacyAccount) -> PathBuf {
        match account.db_dir.as_deref().map(Path::new) {
            Some(d) => {
                let d = if d.is_absolute() { d.to_path_buf() } else { self.dir.join(d) };
                if d.is_dir() {
                    d
                } else {
                    self.dir.clone()
                }
            }
            None => self.dir.clone(),
        }
    }

    /// Message databases of an account, newest year first.
    pub fn message_dbs(&self, account: &LegacyAccount) -> Result<Vec<PathBuf>> {
        let dir = self.db_dir(account);
        let suffix = format!("___{}.db", if account.test_env { 1 } else { 0 });
        let single = format!("{}{}", account.username, suffix);
        let prefix = format!("{}_", account.username);
        let mut dbs: Vec<PathBuf> = std::fs::read_dir(&dir)?
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| {
                *n == single
                    || (n.starts_with(&prefix)
                        && n.ends_with(&suffix)
                        && n[prefix.len()..n.len() - suffix.len()]
                            .chars()
                            .all(|c| c.is_ascii_digit() || c.is_ascii_lowercase()))
            })
            .map(|n| dir.join(n))
            .collect();
        dbs.sort();
        dbs.reverse();
        Ok(dbs)
    }

    pub fn messages(&self, account: &LegacyAccount) -> Result<Vec<MessageSummary>> {
        let mut out = Vec::new();
        for db in self.message_dbs(account)? {
            let c = Self::open_ro(&db)?;
            let file = db.file_name().unwrap().to_string_lossy().into_owned();
            // Databases of old or mobile versions may lack process_state.
            let state = if table_exists(&c, "process_state") {
                "(SELECT state FROM process_state p WHERE p.message_id = m.dmID)"
            } else {
                "0"
            };
            let mut stmt = c.prepare(&format!(
                "SELECT {COLUMNS}, {state}, ifnull(s.specMessFlag, 0) FROM messages m
                 LEFT JOIN supplementary_message_data s ON s.message_id = m.dmID"
            ))?;
            let rows = stmt.query_map([], |r| {
                let time = |i: usize| -> rusqlite::Result<Option<DateTime<Utc>>> {
                    Ok(r.get::<_, Option<String>>(i)?
                        .and_then(|t| parse_legacy_time(&t)))
                };
                Ok(MessageSummary {
                    username: account.username.clone(),
                    dm_id: r.get(0)?,
                    direction: if r.get::<_, Option<i64>>(1)? == Some(2) {
                        Direction::Sent
                    } else {
                        Direction::Received
                    },
                    annotation: r.get(2)?,
                    sender: r.get(3)?,
                    sender_address: r.get(4)?,
                    sender_box_id: r.get(5)?,
                    recipient: r.get(6)?,
                    recipient_address: r.get(7)?,
                    recipient_box_id: r.get(8)?,
                    sender_ref_number: r.get(9)?,
                    recipient_ref_number: r.get(10)?,
                    delivery_time: time(11)?,
                    acceptance_time: time(12)?,
                    status: r.get(13)?,
                    attachments: r.get(14)?,
                    read_locally: r.get::<_, Option<bool>>(15)?.unwrap_or(false),
                    has_zfo: r.get::<_, i64>(16)? > 0,
                    process_state: r.get::<_, Option<i64>>(17)?.unwrap_or(0),
                    suspicious: r.get::<_, i64>(18)? > 0,
                    db_file: file.clone(),
                })
            })?;
            for row in rows {
                out.push(row?);
            }
        }
        out.sort_by(|a, b| b.delivery_time.cmp(&a.delivery_time));
        Ok(out)
    }

    fn find_db(&self, account: &LegacyAccount, dm_id: i64) -> Result<PathBuf> {
        for db in self.message_dbs(account)? {
            let c = Self::open_ro(&db)?;
            let found: Option<i64> = c
                .query_row("SELECT dmID FROM messages WHERE dmID = ?1", [dm_id], |r| {
                    r.get(0)
                })
                .optional()?;
            if found.is_some() {
                return Ok(db);
            }
        }
        Err(Error::Isds {
            code: "not-found".into(),
            text: format!("zpráva {dm_id} není v databázi"),
        })
    }

    /// Signed message (ZFO) as stored by the original app.
    pub fn zfo(&self, account: &LegacyAccount, dm_id: i64) -> Result<Option<Vec<u8>>> {
        self.raw_blob(account, dm_id, "raw_message_data")
    }

    /// Signed delivery info (ZFO).
    pub fn delivery_zfo(&self, account: &LegacyAccount, dm_id: i64) -> Result<Option<Vec<u8>>> {
        self.raw_blob(account, dm_id, "raw_delivery_info_data")
    }

    /// Content of `raw_message_data` or `raw_delivery_info_data`: base64 in
    /// the database, or, when the column is empty (high-volume messages of
    /// the original app since 4.23), a file in the message folder.
    fn raw_blob(
        &self,
        account: &LegacyAccount,
        dm_id: i64,
        table: &str,
    ) -> Result<Option<Vec<u8>>> {
        let db = self.find_db(account, dm_id)?;
        let c = Self::open_ro(&db)?;
        let kind = if table == "raw_message_data" { "message_type" } else { "NULL" };
        let row = c
            .query_row(
                &format!("SELECT data, {kind} FROM {table} WHERE message_id = ?1"),
                [dm_id],
                |r| Ok((column_bytes(r, 0)?, r.get::<_, Option<i64>>(1)?)),
            )
            .optional()?;
        match row {
            None => Ok(None),
            Some((Some(d), _)) if !d.is_empty() => decode_stored(&d).map(Some),
            Some((_, kind)) => {
                let name = match kind {
                    Some(t) => files::message_name(t, dm_id),
                    None => files::delivery_name(dm_id),
                };
                Ok(std::fs::read(files::dir(&db, dm_id).join(name)).ok())
            }
        }
    }

    pub fn attachments(&self, account: &LegacyAccount, dm_id: i64) -> Result<Vec<AttachmentInfo>> {
        let db = self.find_db(account, dm_id)?;
        let c = Self::open_ro(&db)?;
        let mut stmt = c.prepare(
            "SELECT id, _dmFileDescr, _dmMimeType, _dmFileSize, length(dmEncodedContent), attNum
             FROM files WHERE message_id = ?1 ORDER BY attNum, id",
        )?;
        let rows = stmt.query_map([dm_id], |r| {
            let size: Option<i64> = r.get(3)?;
            let b64_len: Option<i64> = r.get(4)?;
            let name: Option<String> = r.get(1)?;
            let num: Option<i64> = r.get(5)?;
            // Kept in a file beside the database (high-volume message).
            let in_file = || {
                let path = files::attachment_path(&db, dm_id, num?, name.as_deref()?)?;
                std::fs::metadata(path).ok().map(|m| m.len() as i64)
            };
            Ok(AttachmentInfo {
                id: r.get(0)?,
                file_name: name.clone().unwrap_or_else(|| "priloha".into()),
                mime_type: r.get(2)?,
                size: size
                    .filter(|s| *s > 0)
                    .or(b64_len.filter(|l| *l > 0).map(|l| l * 3 / 4))
                    .or_else(in_file),
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Content of an attachment: from the database, from its file beside the
    /// database, or, when that is missing too, from the signed message, as
    /// the original app reads it.
    pub fn attachment_content(
        &self,
        account: &LegacyAccount,
        dm_id: i64,
        id: i64,
    ) -> Result<Vec<u8>> {
        let db = self.find_db(account, dm_id)?;
        let c = Self::open_ro(&db)?;
        let (data, num, name) = c.query_row(
            "SELECT dmEncodedContent, attNum, _dmFileDescr FROM files
             WHERE message_id = ?1 AND id = ?2",
            params![dm_id, id],
            |r| {
                Ok((
                    column_bytes(r, 0)?.unwrap_or_default(),
                    r.get::<_, Option<i64>>(1)?,
                    r.get::<_, Option<String>>(2)?,
                ))
            },
        )?;
        drop(c);
        if !data.is_empty() {
            return decode_stored(&data);
        }
        let Some(num) = num.filter(|n| *n >= 0) else {
            return Ok(Vec::new());
        };
        if let Some(path) = name
            .as_deref()
            .and_then(|n| files::attachment_path(&db, dm_id, num, n))
        {
            if let Ok(content) = std::fs::read(path) {
                return Ok(content);
            }
        }
        let zfo = self.zfo(account, dm_id)?.ok_or_else(|| Error::Isds {
            code: "not-found".into(),
            text: format!("příloha zprávy {dm_id} není uložená"),
        })?;
        crate::zfo::parse_message(&zfo)?
            .attachments
            .into_iter()
            .nth(num as usize)
            .map(|a| a.content)
            .ok_or_else(|| Error::Zfo(format!("zpráva {dm_id} nemá přílohu č. {num}")))
    }

    /// Sets the local read flag, exactly like the original app does.
    /// Requires the write lock (see [`lock`]).
    pub fn set_read_locally(
        &self,
        _lock: &lock::WriteLock,
        account: &LegacyAccount,
        dm_id: i64,
        read: bool,
    ) -> Result<()> {
        let c = Self::open_rw(&self.find_db(account, dm_id)?)?;
        c.execute(
            "UPDATE supplementary_message_data SET read_locally = ?2 WHERE message_id = ?1",
            params![dm_id, read],
        )?;
        Ok(())
    }
}

/// Files the original app (since 4.23) keeps beside a message database for
/// high-volume messages, instead of the database columns: the folder is the
/// database path without `.db`, then the message ID.
pub(crate) mod files {
    use std::path::{Path, PathBuf};

    /// `message_type` of `raw_message_data`: 1 received, 2 sent.
    pub fn message_name(message_type: i64, dm_id: i64) -> String {
        if message_type == 1 {
            format!("DDZ_{dm_id}.zfo")
        } else {
            format!("ODZ_{dm_id}.zfo")
        }
    }

    pub fn delivery_name(dm_id: i64) -> String {
        format!("DD_{dm_id}.zfo")
    }

    pub fn dir(db: &Path, dm_id: i64) -> PathBuf {
        db.with_extension("").join(dm_id.to_string())
    }

    /// `ATT_{dmID}_{attNum}_{name}`; `None` for a name that would leave the
    /// folder.
    pub fn attachment_path(db: &Path, dm_id: i64, num: i64, name: &str) -> Option<PathBuf> {
        let safe = !name.is_empty() && !name.contains(['/', '\\']) && name != "..";
        safe.then(|| dir(db, dm_id).join(format!("ATT_{dm_id}_{num}_{name}")))
    }

    /// Writes beside the target first and renames it in place, as the
    /// original does, so the other app never reads half a file.
    pub fn write(path: &Path, data: &[u8]) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut part = path.as_os_str().to_owned();
        part.push(".part");
        let part = PathBuf::from(part);
        std::fs::write(&part, data)?;
        let _ = std::fs::remove_file(path);
        std::fs::rename(&part, path)
    }
}

fn table_exists(c: &Connection, name: &str) -> bool {
    c.query_row(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [name],
        |_| Ok(()),
    )
    .is_ok()
}

/// Reads a column stored either as TEXT or BLOB (the original app uses both).
fn column_bytes(r: &rusqlite::Row, i: usize) -> rusqlite::Result<Option<Vec<u8>>> {
    use rusqlite::types::ValueRef;
    Ok(match r.get_ref(i)? {
        ValueRef::Text(t) | ValueRef::Blob(t) => Some(t.to_vec()),
        _ => None,
    })
}

/// Stored content is base64 text; raw DER (starting with a SEQUENCE tag) is
/// accepted as well.
fn decode_stored(data: &[u8]) -> Result<Vec<u8>> {
    if data.first() == Some(&0x30) {
        return Ok(data.to_vec());
    }
    let clean: Vec<u8> = data
        .iter()
        .copied()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    base64::engine::general_purpose::STANDARD
        .decode(clean)
        .map_err(|e| Error::Zfo(e.to_string()))
}

/// Times are stored as `2026-05-14 16:13:47.409+00:00`.
fn parse_legacy_time(s: &str) -> Option<DateTime<Utc>> {
    parse_time(&s.replacen(' ', "T", 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_text_blob_and_der() {
        assert_eq!(decode_stored(b"aGVz\nbG8=").unwrap(), b"heslo");
        assert_eq!(
            decode_stored(&[0x30, 0x80, 0, 0]).unwrap(),
            vec![0x30, 0x80, 0, 0]
        );
    }

    #[test]
    fn parses_stored_time() {
        let t = parse_legacy_time("2026-05-14 16:13:47.409+00:00").unwrap();
        assert_eq!(t.to_rfc3339(), "2026-05-14T16:13:47.409+00:00");
    }
}

/// Columns added to message databases by newer versions of the original app.
const ADDED_COLUMNS: &[(&str, &str, &str)] = &[
    ("supplementary_message_data", "dmVODZ", "BOOLEAN"),
    ("supplementary_message_data", "attsNum", "INTEGER"),
    ("supplementary_message_data", "specMessFlag", "INTEGER"),
    ("files", "attNum", "INTEGER"),
    ("files", "_dmFileSize", "INTEGER"),
];

/// Adds columns missing in message databases created by older versions, so
/// queries written for the current schema work on them too.
fn upgrade_message_db(path: &Path) {
    let is_message_db = path
        .file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.contains("___") && n.ends_with(".db"));
    if !is_message_db {
        return;
    }
    let Ok(c) = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) else {
        return;
    };
    let _ = c.busy_timeout(std::time::Duration::from_secs(5));
    for (table, column, kind) in ADDED_COLUMNS {
        let present: bool = c
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
                [table, column],
                |r| r.get::<_, i64>(0),
            )
            .map(|n| n > 0)
            .unwrap_or(true);
        if !present {
            let _ = c.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {kind}"));
        }
    }
}

#[cfg(test)]
mod upgrade_tests {
    use super::*;

    #[test]
    fn old_schema_gets_new_columns() {
        let dir = std::env::temp_dir().join(format!("dk-upgrade-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("abc123_2026___0.db");
        let _ = std::fs::remove_file(&path);
        Connection::open(&path)
            .unwrap()
            .execute_batch(
                "CREATE TABLE supplementary_message_data (message_id INTEGER PRIMARY KEY,
                   message_type INTEGER, read_locally BOOLEAN, download_date DATETIME, custom_data TEXT);
                 CREATE TABLE files (id INTEGER PRIMARY KEY, message_id INTEGER, _dmFileDescr TEXT,
                   _dmMimeType TEXT, dmEncodedContent TEXT);",
            )
            .unwrap();
        let c = LegacyStore::open_ro(&path).unwrap();
        c.prepare("SELECT attsNum, dmVODZ, specMessFlag FROM supplementary_message_data")
            .unwrap();
        c.prepare("SELECT attNum, _dmFileSize FROM files").unwrap();
        // Windows does not delete a file that is still open.
        drop(c);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
