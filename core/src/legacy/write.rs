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
             VALUES (?1, NULL, NULL, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL, ?9, NULL, NULL,
                ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24,
                ?25, ?26, ?27, ?28)",
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
            ],
        )?;
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
        std::fs::remove_dir_all(dir).unwrap();
    }
}
