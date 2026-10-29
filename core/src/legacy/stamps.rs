//! When the qualified time stamps of the stored messages expire. A signed
//! message can be proven genuine only while its time stamp is valid; ISDS
//! renews it (ArchiveISDSDocument) in the last year and a half before that.
//! Like `timestamp.db` of the original app, the answer is kept per message,
//! here in `datovka-doplnky.db`, so each message is checked once.

use chrono::{DateTime, Utc};
use serde::Serialize;

use super::lock::WriteLock;
use super::{LegacyAccount, LegacyStore};
use crate::error::Result;
use crate::model::Direction;

#[derive(Debug, Clone, Serialize)]
pub struct StampExpiry {
    pub dm_id: i64,
    pub expires: DateTime<Utc>,
    pub subject: Option<String>,
    pub counterparty: Option<String>,
    pub received: bool,
    pub delivered: Option<DateTime<Utc>>,
}

/// The latest expiry among the time stamps of the message: after a renewal
/// the newest one protects it.
pub fn expiry(zfo: &[u8]) -> Option<DateTime<Utc>> {
    let r = crate::verify::verify_zfo(zfo).ok()?;
    [r.timestamp, r.signature_timestamp]
        .into_iter()
        .flatten()
        .filter_map(|t| t.tsa_cert_not_after)
        .max()
}

impl LegacyStore {
    /// Messages of the account whose time stamp expires before `until`
    /// (expired ones included), soonest first. Messages not checked yet are
    /// checked now; the results are saved when `lock` is given.
    pub fn expiring_stamps(
        &self,
        lock: Option<&WriteLock>,
        account: &LegacyAccount,
        until: DateTime<Utc>,
    ) -> Result<Vec<StampExpiry>> {
        let cache = self.stamp_cache()?;
        let mut fresh = Vec::new();
        let mut out = Vec::new();
        for m in self.messages(account)? {
            if !m.has_zfo {
                continue;
            }
            let key = (account.username.clone(), m.dm_id);
            let expires = match cache.get(&key) {
                Some(v) => v
                    .as_deref()
                    .and_then(|t| DateTime::parse_from_rfc3339(t).ok())
                    .map(|t| t.with_timezone(&Utc)),
                None => {
                    let e = self.zfo(account, m.dm_id)?.as_deref().and_then(expiry);
                    fresh.push((key.0, key.1, e.map(|t| t.to_rfc3339())));
                    e
                }
            };
            let Some(expires) = expires else { continue };
            if expires < until {
                let received = m.direction == Direction::Received;
                out.push(StampExpiry {
                    dm_id: m.dm_id,
                    expires,
                    subject: m.annotation,
                    counterparty: if received { m.sender } else { m.recipient },
                    received,
                    delivered: m.delivery_time.or(m.acceptance_time),
                });
            }
        }
        if let Some(l) = lock {
            self.save_stamps(l, &fresh)?;
        }
        out.sort_by_key(|s| s.expires);
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sample_message_has_a_stamp_that_expires() {
        let Ok(zfo) = std::fs::read("../reference/datovka-qt/tests/data/DZ_6452235.zfo") else {
            return; // reference data not present
        };
        let e = expiry(&zfo).expect("the sample has a qualified time stamp");
        assert!(e.timestamp() > 1_300_000_000, "{e}");
        assert_eq!(expiry(b"not a zfo"), None);
    }

    #[test]
    fn expiring_messages_are_listed_and_remembered() {
        use crate::legacy::lock;
        let Ok(zfo) = std::fs::read("../reference/datovka-qt/tests/data/DZ_6452235.zfo") else {
            return;
        };
        let dir = std::env::temp_dir().join(format!("datovka-stamps-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let tpl = rusqlite::Connection::open(dir.join("tpl_2000___0.db")).unwrap();
        tpl.execute_batch(include_str!("schema.sql")).unwrap();
        drop(tpl);
        std::fs::write(dir.join("dsgui.conf"), "[credentials]\nname=T\nusername=abc\n").unwrap();
        let store = LegacyStore::new(&dir);
        let acc = store.account("abc").unwrap();
        let lock::Acquire::Acquired(l) = lock::acquire(&dir, "t").unwrap() else {
            panic!()
        };
        store.insert_message(&l, &acc, Direction::Received, &zfo, None).unwrap();

        let far = Utc::now() + chrono::Duration::days(365 * 100);
        let list = store.expiring_stamps(Some(&l), &acc, far).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].dm_id, 6452235);
        assert!(list[0].received);
        assert_eq!(store.stamp_cache().unwrap().len(), 1, "remembered");

        let long_ago = DateTime::parse_from_rfc3339("2000-01-01T00:00:00Z").unwrap().with_timezone(&Utc);
        assert!(store.expiring_stamps(None, &acc, long_ago).unwrap().is_empty());
        store.forget_stamp(&l, "abc", 6452235).unwrap();
        assert!(store.stamp_cache().unwrap().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Reads a real archive given in DATOVKA_DIR, without writing anything:
    /// `cargo test -p datovka-core real_archive -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn real_archive() {
        let Ok(dir) = std::env::var("DATOVKA_DIR") else { return };
        let store = LegacyStore::new(&dir);
        let until = Utc::now() + chrono::Duration::days(365 * 3);
        for acc in store.accounts().unwrap() {
            let t = std::time::Instant::now();
            let n = store.messages(&acc).unwrap().len();
            let list = store.expiring_stamps(None, &acc, until).unwrap();
            println!("{}: {n} zpráv, {} razítek vyprší do 3 let, {:?}", acc.name, list.len(), t.elapsed());
            for e in list.iter().take(3) {
                println!("  {} {}", e.expires.date_naive(), e.subject.clone().unwrap_or_default());
            }
        }
    }
}
