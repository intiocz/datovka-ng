//! Marks ISDS puts on messages after they were stored.

use rusqlite::params;

use super::lock::WriteLock;
use super::{LegacyAccount, LegacyStore};
use crate::error::Result;

impl LegacyStore {
    /// Stores `specMessFlag` (ISDS marked the message as suspicious) where
    /// the original app keeps it. The mark can come days after delivery.
    pub fn set_spec_mess_flag(
        &self,
        _lock: &WriteLock,
        account: &LegacyAccount,
        dm_id: i64,
        flag: i64,
    ) -> Result<()> {
        let c = Self::open_rw(&self.find_db(account, dm_id)?)?;
        c.execute(
            "UPDATE supplementary_message_data SET specMessFlag = ?2
             WHERE message_id = ?1 AND ifnull(specMessFlag, -1) <> ?2",
            params![dm_id, flag],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::legacy::lock;
    use crate::model::Direction;

    #[test]
    fn a_suspicious_mark_shows_in_the_list() {
        let Ok(zfo) = std::fs::read("../reference/datovka-qt/tests/data/DZ_6452235.zfo") else {
            return; // reference data not present
        };
        let dir = std::env::temp_dir().join(format!("datovka-flags-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let tpl = rusqlite::Connection::open(dir.join("tpl_2000___0.db")).unwrap();
        tpl.execute_batch(include_str!("schema.sql")).unwrap();
        drop(tpl);
        std::fs::write(dir.join("dsgui.conf"), "[credentials]\nname=T\nusername=abc\n").unwrap();
        let store = LegacyStore::new(&dir);
        let acc = store.account("abc").unwrap();
        let lock::Acquire::Acquired(l) = lock::acquire(&dir, "test").unwrap() else {
            panic!()
        };
        store.insert_message(&l, &acc, Direction::Received, &zfo, None).unwrap();
        assert!(!store.messages(&acc).unwrap()[0].suspicious);
        store.set_spec_mess_flag(&l, &acc, 6452235, 1).unwrap();
        assert!(store.messages(&acc).unwrap()[0].suspicious);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
