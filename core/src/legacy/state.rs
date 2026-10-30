//! Later states of stored messages: delivered, accepted (doručena), read,
//! moved to the vault. After every list download the original app compares
//! the state in the list with the stored one and updates the envelope, and
//! for a changed message downloads the signed delivery info again
//! (`TaskDownloadMessageList`, `updateMessageState`).

use base64::Engine;
use rusqlite::{params, OptionalExtension};

use super::lock::WriteLock;
use super::write::db_time;
use super::{files, LegacyAccount, LegacyStore};
use crate::envelope::parse_time;
use crate::error::Result;
use crate::model::Envelope;

/// `dmMessageStatus` of a message delivered by fiction, by login, or read.
const ACCEPTED: std::ops::RangeInclusive<i64> = 5..=7;
/// `dmMessageStatus` of a message in the data vault.
const IN_VAULT: i64 = 10;

/// Whether a list entry says something new about a stored message, by the
/// rule of the original app: the status or the type changed. A delivered
/// message that only moved to the vault is left as it is.
pub fn state_changed(stored_status: Option<i64>, stored_type: Option<&str>, env: &Envelope) -> bool {
    let Some(new) = env.message_status.map(i64::from) else {
        return false;
    };
    if new == IN_VAULT && stored_status.is_some_and(|s| ACCEPTED.contains(&s)) {
        return false;
    }
    Some(new) != stored_status
        || env
            .dm_type
            .as_deref()
            .is_some_and(|t| !t.is_empty() && Some(t) != stored_type.filter(|s| !s.is_empty()))
}

/// The list entry makes a stored message accepted (doručena) just now.
pub fn became_accepted(stored_status: Option<i64>, env: &Envelope) -> bool {
    env.message_status
        .map(i64::from)
        .is_some_and(|s| ACCEPTED.contains(&s))
        && !stored_status.is_some_and(|s| ACCEPTED.contains(&s))
}

impl LegacyStore {
    /// `dmMessageStatus` and `_dmType` of a stored message.
    pub fn stored_state(
        &self,
        account: &LegacyAccount,
        dm_id: i64,
    ) -> Result<(Option<i64>, Option<String>)> {
        let c = Self::open_ro(&self.find_db(account, dm_id)?)?;
        Ok(c.query_row(
            "SELECT dmMessageStatus, _dmType FROM messages WHERE dmID = ?1",
            [dm_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?)
    }

    /// Stores the newer state of a message from a list entry: status, times
    /// and type. With `delivery` (the signed delivery info downloaded again)
    /// also that and its events, added or updated by time as the original
    /// does. A message kept in files gets the delivery info in its file.
    pub fn update_state(
        &self,
        _lock: &WriteLock,
        account: &LegacyAccount,
        dm_id: i64,
        env: &Envelope,
        delivery: Option<&[u8]>,
    ) -> Result<()> {
        let db = self.find_db(account, dm_id)?;
        let mut c = Self::open_rw(&db)?;
        let tx = c.transaction()?;
        tx.execute(
            "UPDATE messages SET dmMessageStatus = ifnull(?2, dmMessageStatus),
                dmDeliveryTime = ifnull(?3, dmDeliveryTime),
                dmAcceptanceTime = ifnull(?4, dmAcceptanceTime),
                _dmType = ifnull(nullif(?5, ''), _dmType)
             WHERE dmID = ?1",
            params![
                dm_id,
                env.message_status.map(i64::from),
                env.delivery_time.map(db_time),
                env.acceptance_time.map(db_time),
                env.dm_type,
            ],
        )?;
        if let Some(di) = delivery {
            let in_files: bool = tx
                .query_row(
                    "SELECT data IS NULL FROM raw_message_data WHERE message_id = ?1",
                    [dm_id],
                    |r| r.get(0),
                )
                .optional()?
                .unwrap_or(false);
            let data = if in_files {
                files::write(&files::dir(&db, dm_id).join(files::delivery_name(dm_id)), di)?;
                None
            } else {
                // Base64 bound as bytes, as the original binds QByteArray.
                Some(base64::engine::general_purpose::STANDARD.encode(di).into_bytes())
            };
            tx.execute(
                "INSERT OR REPLACE INTO raw_delivery_info_data (message_id, data) VALUES (?1, ?2)",
                params![dm_id, data],
            )?;
            for (t, descr) in crate::zfo::delivery_events(di).unwrap_or_default() {
                let t = parse_time(&t).map(db_time).unwrap_or(t);
                let n = tx.execute(
                    "UPDATE events SET dmEventDescr = ?3 WHERE message_id = ?1 AND dmEventTime = ?2",
                    params![dm_id, t, descr],
                )?;
                if n == 0 {
                    tx.execute(
                        "INSERT INTO events (message_id, dmEventTime, dmEventDescr) VALUES (?1, ?2, ?3)",
                        params![dm_id, t, descr],
                    )?;
                }
            }
        }
        tx.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(status: Option<u8>, kind: Option<&str>) -> Envelope {
        Envelope {
            dm_id: "1".into(),
            message_status: status,
            dm_type: kind.map(str::to_string),
            ..Default::default()
        }
    }

    #[test]
    fn a_new_status_or_type_is_a_change_the_vault_is_not() {
        assert!(state_changed(Some(4), Some("V"), &env(Some(6), Some("V"))));
        assert!(!state_changed(Some(6), Some("V"), &env(Some(6), Some("V"))));
        assert!(state_changed(Some(6), None, &env(Some(6), Some("V"))), "type filled in");
        assert!(!state_changed(Some(6), Some("V"), &env(Some(10), Some("V"))), "vault after delivery");
        assert!(state_changed(Some(4), Some("V"), &env(Some(10), Some("V"))));
        assert!(!state_changed(Some(4), None, &env(None, None)));
    }

    /// A store with one account and the sample message stored, in the
    /// database or (`big`) in files.
    fn stored(name: &str, big: bool) -> Option<(std::path::PathBuf, LegacyStore, Vec<u8>)> {
        let zfo = std::fs::read("../reference/datovka-qt/tests/data/DZ_6452235.zfo").ok()?;
        let di = std::fs::read("../reference/datovka-qt/tests/data/DD_6452235.zfo").ok()?;
        let dir = std::env::temp_dir().join(format!("datovka-state-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let tpl = rusqlite::Connection::open(dir.join("tpl_2000___0.db")).unwrap();
        tpl.execute_batch(include_str!("schema.sql")).unwrap();
        drop(tpl);
        std::fs::write(dir.join("dsgui.conf"), "[credentials]\nname=T\nusername=abc\n").unwrap();
        let store = LegacyStore::new(&dir);
        let acc = store.account("abc").unwrap();
        let crate::legacy::lock::Acquire::Acquired(l) =
            crate::legacy::lock::acquire(&dir, "test").unwrap()
        else {
            panic!()
        };
        store
            .insert_message_as(&l, &acc, crate::model::Direction::Sent, &zfo, Some(&di), big)
            .unwrap();
        Some((dir, store, di))
    }

    #[test]
    fn a_later_state_updates_the_envelope_and_the_delivery_info() {
        for big in [false, true] {
            let Some((dir, store, di)) = stored(if big { "files" } else { "db" }, big) else {
                return; // reference data not present
            };
            let acc = store.account("abc").unwrap();
            let crate::legacy::lock::Acquire::Acquired(l) =
                crate::legacy::lock::acquire(&dir, "test").unwrap()
            else {
                panic!()
            };
            let before = store.messages(&acc).unwrap()[0].clone();
            let events = |store: &LegacyStore| -> i64 {
                let db = store.message_dbs(&acc).unwrap()[0].clone();
                rusqlite::Connection::open(db)
                    .unwrap()
                    .query_row("SELECT COUNT(*) FROM events", [], |r| r.get(0))
                    .unwrap()
            };
            let events_before = events(&store);

            let accepted = parse_time("2026-10-30T09:15:00.000+01:00").unwrap();
            let later = Envelope {
                dm_id: "6452235".into(),
                message_status: Some(6),
                acceptance_time: Some(accepted),
                dm_type: Some("V".into()),
                ..Default::default()
            };
            let (status, kind) = store.stored_state(&acc, 6452235).unwrap();
            assert!(state_changed(status, kind.as_deref(), &later));
            store.update_state(&l, &acc, 6452235, &later, Some(&di)).unwrap();

            let after = store.messages(&acc).unwrap()[0].clone();
            assert_eq!(after.status, Some(6));
            assert_eq!(after.acceptance_time, Some(accepted));
            assert_eq!(after.delivery_time, before.delivery_time, "kept when not in the list");
            assert_eq!(store.stored_state(&acc, 6452235).unwrap().1.as_deref(), Some("V"));
            assert_eq!(store.delivery_zfo(&acc, 6452235).unwrap().unwrap(), di);
            assert_eq!(events(&store), events_before, "the same events are not added twice");
            let (status, kind) = store.stored_state(&acc, 6452235).unwrap();
            assert!(!state_changed(status, kind.as_deref(), &later), "nothing new the next time");
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn accepted_only_once() {
        assert!(became_accepted(Some(4), &env(Some(6), None)));
        assert!(became_accepted(Some(4), &env(Some(5), None)));
        assert!(!became_accepted(Some(6), &env(Some(7), None)));
        assert!(!became_accepted(Some(4), &env(Some(8), None)));
    }
}
