//! Storing messages downloaded from ISDS in the original Datovka databases,
//! mirroring what `MessageDb` of the original app writes.

use std::path::PathBuf;

use base64::Engine;
use chrono::{DateTime, Datelike, Utc};
use rusqlite::{params, Connection};

use super::lock::WriteLock;
use super::{LegacyAccount, LegacyStore};
use crate::envelope::parse_time;
use crate::error::{Error, Result};
use crate::model::{Direction, Message};

/// `yyyy-MM-dd HH:mm:ss.zzz+00:00` in UTC, as `qDateTimeToDbFormat` stores it.
pub(crate) fn db_time(t: DateTime<Utc>) -> String {
    t.format("%Y-%m-%d %H:%M:%S%.3f+00:00").to_string()
}

/// The message hash and the signing certificate, stored as the original
/// app does (`hashes`, `certificate_data`, `message_certificate_data`).
fn store_signature_details(
    c: &Connection,
    dm_id: i64,
    zfo: &[u8],
    report: Option<&crate::verify::SignatureReport>,
) -> Result<()> {
    if let Some(h) = report.and_then(|r| r.dm_hash.as_ref()) {
        c.execute("DELETE FROM hashes WHERE message_id = ?1", [dm_id])?;
        c.execute(
            "INSERT INTO hashes (message_id, value, _algorithm) VALUES (?1, ?2, ?3)",
            params![dm_id, h.value, h.algorithm],
        )?;
    }
    if let Some(der) = crate::verify::signer_certificate(zfo) {
        // Base64 bound as bytes, as the original binds QByteArray.
        let cert = base64::engine::general_purpose::STANDARD.encode(der).into_bytes();
        let found: Option<i64> = c
            .query_row("SELECT id FROM certificate_data WHERE der_data = ?1", [&cert], |r| r.get(0))
            .ok();
        let id = match found {
            Some(id) => id,
            None => {
                let next: i64 =
                    c.query_row("SELECT ifnull(max(id), 0) + 1 FROM certificate_data", [], |r| r.get(0))?;
                c.execute(
                    "INSERT INTO certificate_data (id, der_data) VALUES (?1, ?2)",
                    params![next, cert],
                )?;
                next
            }
        };
        c.execute("DELETE FROM message_certificate_data WHERE message_id = ?1", [dm_id])?;
        c.execute(
            "INSERT INTO message_certificate_data (message_id, certificate_id) VALUES (?1, ?2)",
            params![dm_id, id],
        )?;
    }
    Ok(())
}

const TYPE_RECEIVED: i64 = 1;
const TYPE_SENT: i64 = 2;
const PROCESS_STATE_UNSETTLED: i64 = 0;

impl LegacyStore {
    /// Database file for a message, split by the year of delivery like the
    /// original (`inv` when the time is unknown).
    fn target_db(&self, account: &LegacyAccount, delivery: Option<DateTime<Utc>>) -> PathBuf {
        let key = delivery
            .map(|t| format!("{:04}", t.year()))
            .unwrap_or_else(|| "inv".into());
        self.dir.join(format!(
            "{}_{}___{}.db",
            account.username,
            key,
            if account.test_env { 1 } else { 0 }
        ))
    }

    /// Creates a message database with the current schema of the original app.
    fn create_db(&self, path: &PathBuf) -> Result<()> {
        let dst = Connection::open(path)?;
        dst.execute_batch("PRAGMA journal_mode = DELETE;")?;
        dst.execute_batch(include_str!("schema.sql"))?;
        Ok(())
    }

    /// Whether a message is already stored in any database of the account.
    pub fn contains(&self, account: &LegacyAccount, dm_id: i64) -> Result<bool> {
        Ok(self.find_db(account, dm_id).is_ok())
    }

    /// Stores a downloaded signed message, its delivery info and attachments.
    /// Does nothing when the message is already stored.
    pub fn insert_message(
        &self,
        _lock: &WriteLock,
        account: &LegacyAccount,
        direction: Direction,
        zfo: &[u8],
        delivery_zfo: Option<&[u8]>,
    ) -> Result<bool> {
        let msg: Message = crate::zfo::parse_message(zfo)?;
        let e = &msg.envelope;
        let dm_id: i64 = e
            .dm_id
            .parse()
            .map_err(|_| Error::Zfo(format!("neplatné ID zprávy {}", e.dm_id)))?;
        if self.contains(account, dm_id)? {
            return Ok(false);
        }
        let path = self.target_db(account, e.delivery_time.or(e.acceptance_time));
        if !path.exists() {
            self.create_db(&path)?;
        }
        // Like the original: whether the signature holds, the message hash
        // and the signing certificate go with the complete message.
        let report = crate::verify::verify_zfo(zfo).ok();
        let mut c = Self::open_rw(&path)?;
        let tx = c.transaction()?;
        let b64 = |d: &[u8]| base64::engine::general_purpose::STANDARD.encode(d);
        let time = |t: Option<DateTime<Utc>>| t.map(db_time);

        tx.execute(
            "INSERT INTO messages (dmID, is_verified, _origin, dbIDSender, dmSender,
                dmSenderAddress, dmSenderType, dmRecipient, dmRecipientAddress,
                dmAmbiguousRecipient, dmSenderOrgUnit, dmSenderOrgUnitNum, dbIDRecipient,
                dmRecipientOrgUnit, dmRecipientOrgUnitNum, dmToHands, dmAnnotation,
                dmRecipientRefNumber, dmSenderRefNumber, dmRecipientIdent, dmSenderIdent,
                dmLegalTitleLaw, dmLegalTitleYear, dmLegalTitleSect, dmLegalTitlePar,
                dmLegalTitlePoint, dmPersonalDelivery, dmAllowSubstDelivery, dmQTimestamp,
                dmDeliveryTime, dmAcceptanceTime, dmMessageStatus, dmAttachmentSize, _dmType)
             VALUES (?1, ?29, 'tReturnedMessage', ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, ?9,
                NULL, NULL, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22,
                ?23, ?24, ?25, ?26, ?27, ?28)",
            params![
                dm_id,
                e.sender_box_id,
                e.sender,
                e.sender_address,
                e.sender_type,
                e.recipient,
                e.recipient_address,
                e.ambiguous_recipient,
                e.recipient_box_id,
                e.to_hands,
                e.annotation,
                e.recipient_ref_number,
                e.sender_ref_number,
                e.recipient_ident,
                e.sender_ident,
                e.legal_title_law,
                e.legal_title_year,
                e.legal_title_sect,
                e.legal_title_par,
                e.legal_title_point,
                e.personal_delivery,
                e.allow_subst_delivery,
                e.qtimestamp_b64,
                time(e.delivery_time),
                time(e.acceptance_time),
                e.message_status,
                e.attachment_size_kb.map(|v| v as i64),
                e.dm_type,
                report.as_ref().map(|r| r.signature_valid),
            ],
        )?;
        store_signature_details(&tx, dm_id, zfo, report.as_ref())?;
        let received = direction == Direction::Received;
        tx.execute(
            "INSERT INTO supplementary_message_data (message_id, message_type, dmVODZ, attsNum,
                specMessFlag, read_locally, download_date, custom_data)
             VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?6, 'null')",
            params![
                dm_id,
                if received { TYPE_RECEIVED } else { TYPE_SENT },
                e.vodz.unwrap_or(false),
                e.atts_num.unwrap_or(msg.attachments.len() as i64),
                !received,
                db_time(Utc::now()),
            ],
        )?;
        tx.execute(
            "INSERT INTO process_state (message_id, state) VALUES (?1, ?2)",
            params![dm_id, PROCESS_STATE_UNSETTLED],
        )?;
        for (i, a) in msg.attachments.iter().enumerate() {
            tx.execute(
                "INSERT INTO files (message_id, attNum, _dmFileDescr, _dmUpFileGuid, _dmFileGuid,
                    _dmMimeType, _dmFormat, _dmFileMetaType, dmEncodedContent)
                 VALUES (?1, ?2, ?3, NULL, NULL, ?4, NULL, ?5, ?6)",
                params![
                    dm_id,
                    i as i64,
                    a.file_name,
                    a.mime_type,
                    a.meta_type,
                    b64(&a.content)
                ],
            )?;
        }
        // The original binds QByteArray::toBase64(), which SQLite stores as BLOB.
        tx.execute(
            "INSERT OR REPLACE INTO raw_message_data (message_id, message_type, data)
             VALUES (?1, ?2, ?3)",
            params![
                dm_id,
                if received { TYPE_RECEIVED } else { TYPE_SENT },
                b64(zfo).into_bytes()
            ],
        )?;
        if let Some(di) = delivery_zfo {
            tx.execute(
                "INSERT OR REPLACE INTO raw_delivery_info_data (message_id, data) VALUES (?1, ?2)",
                params![dm_id, b64(di).into_bytes()],
            )?;
            for (t, descr) in crate::zfo::delivery_events(di).unwrap_or_default() {
                let t = parse_time(&t).map(db_time).unwrap_or(t);
                tx.execute(
                    "INSERT INTO events (message_id, dmEventTime, dmEventDescr) VALUES (?1, ?2, ?3)",
                    params![dm_id, t, descr],
                )?;
            }
        }
        tx.commit()?;
        Ok(true)
    }
}

impl LegacyStore {
    /// Completes messages that earlier versions of Datovka NG stored without
    /// what the original app keeps with a complete message: the signature
    /// result, the download marker, the hash and the signing certificate.
    /// Without them the original shows such a message as not downloaded in
    /// its signature details. Returns the number of messages completed.
    pub fn complete_signature_details(&self, _lock: &WriteLock, account: &LegacyAccount) -> Result<usize> {
        let mut done = 0;
        for path in self.message_dbs(account)? {
            let mut c = Self::open_rw(&path)?;
            let rows: Vec<(i64, Vec<u8>)> = {
                let mut st = c.prepare(
                    "SELECT m.dmID, r.data FROM messages m
                     JOIN raw_message_data r ON r.message_id = m.dmID
                     WHERE m._origin IS NULL AND m.is_verified IS NULL",
                )?;
                let rows = st.query_map([], |r| Ok((r.get(0)?, r.get::<_, Vec<u8>>(1)?)))?;
                rows.collect::<std::result::Result<_, _>>()?
            };
            if rows.is_empty() {
                continue;
            }
            let tx = c.transaction()?;
            for (dm_id, data) in rows {
                let Ok(zfo) = base64::engine::general_purpose::STANDARD.decode(&data) else {
                    continue;
                };
                let report = crate::verify::verify_zfo(&zfo).ok();
                tx.execute(
                    "UPDATE messages SET is_verified = ?2, _origin = 'tReturnedMessage' WHERE dmID = ?1",
                    params![dm_id, report.as_ref().map(|r| r.signature_valid)],
                )?;
                store_signature_details(&tx, dm_id, &zfo, report.as_ref())?;
                done += 1;
            }
            tx.commit()?;
        }
        Ok(done)
    }

    /// Removes a message and everything stored with it from this computer,
    /// like the original app: certificates only when no other message uses
    /// them. Tags, notes and deadlines stay, so a message downloaded again
    /// gets them back.
    pub fn delete_message(&self, _lock: &WriteLock, account: &LegacyAccount, dm_id: i64) -> Result<()> {
        let mut c = Self::open_rw(&self.find_db(account, dm_id)?)?;
        let tx = c.transaction()?;
        let certs: Vec<i64> = {
            let mut st =
                tx.prepare("SELECT certificate_id FROM message_certificate_data WHERE message_id = ?1")?;
            let rows = st.query_map([dm_id], |r| r.get(0))?;
            rows.collect::<std::result::Result<_, _>>()?
        };
        for table in [
            "hashes",
            "files",
            "events",
            "raw_message_data",
            "raw_delivery_info_data",
            "supplementary_message_data",
            "message_certificate_data",
            "process_state",
        ] {
            // Older databases may lack a table.
            let _ = tx.execute(&format!("DELETE FROM {table} WHERE message_id = ?1"), [dm_id]);
        }
        for id in certs {
            tx.execute(
                "DELETE FROM certificate_data WHERE id = ?1
                 AND NOT EXISTS (SELECT 1 FROM message_certificate_data WHERE certificate_id = ?1)",
                [id],
            )?;
        }
        tx.execute("DELETE FROM messages WHERE dmID = ?1", [dm_id])?;
        tx.commit()?;
        Ok(())
    }

    /// Processing state of a message as the original app keeps it:
    /// 0 unsettled, 1 in progress, 2 settled.
    pub fn set_process_state(
        &self,
        _lock: &WriteLock,
        account: &LegacyAccount,
        dm_id: i64,
        state: i64,
    ) -> Result<()> {
        if !(0..=2).contains(&state) {
            return Err(Error::Zfo(format!("neznámý stav vyřízení {state}")));
        }
        let c = Self::open_rw(&self.find_db(account, dm_id)?)?;
        // Databases of old or mobile versions may lack the table.
        c.execute_batch(
            "CREATE TABLE IF NOT EXISTS process_state (
                message_id INTEGER NOT NULL,
                state INTEGER,
                PRIMARY KEY (message_id),
                FOREIGN KEY(message_id) REFERENCES messages (dmID)
            );",
        )?;
        c.execute(
            "INSERT OR REPLACE INTO process_state (message_id, state) VALUES (?1, ?2)",
            params![dm_id, state],
        )?;
        Ok(())
    }

    /// Replaces the stored signed message, e.g. after time stamp renewal.
    pub fn replace_zfo(
        &self,
        _lock: &WriteLock,
        account: &LegacyAccount,
        dm_id: i64,
        zfo: &[u8],
    ) -> Result<()> {
        let c = Self::open_rw(&self.find_db(account, dm_id)?)?;
        let n = c.execute(
            "UPDATE raw_message_data SET data = ?2 WHERE message_id = ?1",
            params![
                dm_id,
                base64::engine::general_purpose::STANDARD
                    .encode(zfo)
                    .into_bytes()
            ],
        )?;
        if n == 0 {
            return Err(Error::Zfo(format!("zpráva {dm_id} nemá uložený originál")));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::legacy::lock;

    const SAMPLE: &str = "../reference/datovka-qt/tests/data/DZ_6452235.zfo";
    const DELIVERY: &str = "../reference/datovka-qt/tests/data/DD_6452235.zfo";

    #[test]
    fn inserts_message_readable_back() {
        let Ok(zfo) = std::fs::read(SAMPLE) else {
            return; // reference data not present
        };
        let di = std::fs::read(DELIVERY).ok();
        let dir = std::env::temp_dir().join(format!("datovka-legacy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // Minimal template database with the original schema.
        let tpl = Connection::open(dir.join("tpl_2000___0.db")).unwrap();
        tpl.execute_batch(include_str!("schema.sql")).unwrap();
        drop(tpl);
        std::fs::write(
            dir.join("dsgui.conf"),
            "[credentials]\nname=T\nusername=abc\n",
        )
        .unwrap();

        let store = LegacyStore::new(&dir);
        let acc = store.account("abc").unwrap();
        let lock::Acquire::Acquired(l) = lock::acquire(&dir, "test").unwrap() else {
            panic!()
        };
        assert!(store
            .insert_message(&l, &acc, Direction::Received, &zfo, di.as_deref())
            .unwrap());
        assert!(!store
            .insert_message(&l, &acc, Direction::Received, &zfo, di.as_deref())
            .unwrap());

        let msgs = store.messages(&acc).unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].dm_id, 6452235);
        assert!(!msgs[0].read_locally);
        assert_eq!(store.zfo(&acc, 6452235).unwrap().unwrap(), zfo);
        let atts = store.attachments(&acc, 6452235).unwrap();
        assert_eq!(atts.len(), 2);
        assert_eq!(
            store
                .attachment_content(&acc, 6452235, atts[0].id)
                .unwrap()
                .len(),
            8
        );
        assert!(dir.join("abc_2018___0.db").exists());

        // Stored like the original stores a complete message.
        let c = Connection::open(dir.join("abc_2018___0.db")).unwrap();
        let count = |sql: &str| -> i64 { c.query_row(sql, [], |r| r.get(0)).unwrap() };
        let complete = |c: &Connection| -> (Option<bool>, Option<String>) {
            c.query_row("SELECT is_verified, _origin FROM messages", [], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
        };
        let (verified, origin) = complete(&c);
        assert!(verified.is_some());
        assert_eq!(origin.as_deref(), Some("tReturnedMessage"));
        assert_eq!(count("SELECT COUNT(*) FROM hashes WHERE value <> '' AND _algorithm <> ''"), 1);
        assert_eq!(count("SELECT COUNT(*) FROM message_certificate_data"), 1);
        assert_eq!(count("SELECT typeof(der_data) = 'blob' FROM certificate_data"), 1);

        // A message stored by an older version gets completed once.
        c.execute_batch(
            "UPDATE messages SET is_verified = NULL, _origin = NULL;
             DELETE FROM hashes; DELETE FROM message_certificate_data;",
        )
        .unwrap();
        assert_eq!(store.complete_signature_details(&l, &acc).unwrap(), 1);
        assert_eq!(complete(&c), (verified, origin));
        assert_eq!(count("SELECT COUNT(*) FROM hashes"), 1);
        assert_eq!(count("SELECT COUNT(*) FROM message_certificate_data"), 1);
        assert_eq!(count("SELECT COUNT(*) FROM certificate_data"), 1, "the certificate is reused");
        assert_eq!(store.complete_signature_details(&l, &acc).unwrap(), 0);
        drop(c);

        assert_eq!(msgs[0].process_state, 0, "a new message is unsettled");
        store.set_process_state(&l, &acc, 6452235, 2).unwrap();
        assert_eq!(store.messages(&acc).unwrap()[0].process_state, 2);
        assert!(store.set_process_state(&l, &acc, 6452235, 7).is_err());

        store.delete_message(&l, &acc, 6452235).unwrap();
        assert!(store.messages(&acc).unwrap().is_empty());
        assert!(!store.contains(&acc, 6452235).unwrap());
        let c = Connection::open(dir.join("abc_2018___0.db")).unwrap();
        for table in [
            "files",
            "events",
            "raw_message_data",
            "raw_delivery_info_data",
            "process_state",
            "hashes",
            "message_certificate_data",
            "certificate_data",
        ] {
            let n: i64 = c
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .unwrap();
            assert_eq!(n, 0, "{table} is empty after deleting");
        }
        // Stored again, as after downloading it once more.
        assert!(store
            .insert_message(&l, &acc, Direction::Received, &zfo, di.as_deref())
            .unwrap());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
