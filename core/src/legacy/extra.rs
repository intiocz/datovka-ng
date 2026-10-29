//! Tags and notes (`tag.db`, schema of the original app: tables `tags`,
//! `message_tags`, `notes` and `message_notes` keyed by `test_env`), and
//! message deadlines and drafts
//! (`datovka-doplnky.db`, new in DATOVKA). All live in the shared folder.

use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use super::lock::WriteLock;
use super::LegacyStore;
use crate::error::Result;

/// Schema of the original Datovka `tag.db`. `id` is not an integer primary
/// key alias, so inserts supply it.
const TAG_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS tags (
    id INTEGER NOT NULL,
    tag_name TEXT NOT NULL,
    tag_color TEXT,
    tag_description TEXT,
    CONSTRAINT pk_id PRIMARY KEY (id),
    CONSTRAINT uq_tag_name UNIQUE (tag_name)
);
CREATE TABLE IF NOT EXISTS message_tags (
    id INTEGER NOT NULL,
    test_env INTEGER NOT NULL,
    message_id INTEGER NOT NULL,
    tag_id INTEGER NOT NULL,
    CONSTRAINT pk_id PRIMARY KEY (id),
    CONSTRAINT fk_tag_id FOREIGN KEY(tag_id) REFERENCES tags (id) ON DELETE CASCADE,
    CONSTRAINT uq_test_env_message_id_tag_id UNIQUE (test_env, message_id, tag_id),
    CONSTRAINT ck_test_env CHECK (test_env IN (0, 1))
);";

/// Notes of newer versions of the original app, also in `tag.db`.
const NOTE_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS notes (
    id INTEGER NOT NULL,
    note_content TEXT NOT NULL,
    CONSTRAINT pk_id PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS message_notes (
    id INTEGER NOT NULL,
    test_env INTEGER NOT NULL,
    message_id INTEGER NOT NULL,
    note_id INTEGER NOT NULL,
    CONSTRAINT pk_id PRIMARY KEY (id),
    CONSTRAINT fk_note_id FOREIGN KEY(note_id) REFERENCES notes (id) ON DELETE CASCADE,
    CONSTRAINT uq_test_env_message_id_note_id UNIQUE (test_env, message_id, note_id),
    CONSTRAINT ck_test_env CHECK (test_env IN (0, 1))
);";

const EXTRA_DB: &str = "datovka-doplnky.db";
const EXTRA_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS deadlines (
    user_name TEXT NOT NULL,
    message_id INTEGER NOT NULL,
    deadline TEXT NOT NULL,
    note TEXT,
    PRIMARY KEY (user_name, message_id)
);
CREATE TABLE IF NOT EXISTS drafts (
    id INTEGER PRIMARY KEY,
    user_name TEXT NOT NULL,
    content TEXT NOT NULL,
    updated TEXT NOT NULL
);";

#[derive(Debug, Clone, Serialize)]
pub struct Draft {
    pub id: i64,
    pub user_name: String,
    /// Compose form as JSON, owned by the app.
    pub content: String,
    pub updated: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Tag {
    pub id: i64,
    pub name: String,
    pub color: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MessageMark {
    pub user_name: String,
    /// Original Datovka stores a tag on the testing environment, not on a login.
    pub test_env: bool,
    pub message_id: i64,
    pub value: String,
}

impl LegacyStore {
    fn open_aux(&self, file: &str, schema: &str, write: bool) -> Result<Option<Connection>> {
        let path = self.dir.join(file);
        // Early builds named the file datovka-lhuty.db.
        let old = self.dir.join("datovka-lhuty.db");
        if file == EXTRA_DB && !path.exists() && old.exists() {
            std::fs::rename(&old, &path)?;
        }
        if !path.exists() && !write {
            return Ok(None);
        }
        let c = if write {
            Self::open_create(&path)?
        } else {
            Self::open_ro(&path)?
        };
        if write {
            c.execute_batch(schema)?;
        }
        Ok(Some(c))
    }

    fn open_tags(&self, write: bool) -> Result<Option<Connection>> {
        let path = self.dir.join("tag.db");
        if !path.exists() && !write {
            return Ok(None);
        }
        let c = if write {
            Self::open_create(&path)?
        } else {
            Self::open_ro(&path)?
        };
        if write && !table_exists(&c, "tags")? {
            c.execute_batch(TAG_SCHEMA)?;
        }
        Ok(Some(c))
    }

    pub fn tags(&self) -> Result<Vec<Tag>> {
        let Some(c) = self.open_tags(false)? else {
            return Ok(Vec::new());
        };
        if !table_exists(&c, "tags")? {
            return Ok(Vec::new());
        }
        let mut st = c.prepare("SELECT id, tag_name, tag_color FROM tags ORDER BY tag_name")?;
        let rows = st.query_map([], |r| {
            Ok(Tag {
                id: r.get(0)?,
                name: r.get(1)?,
                color: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Tag assignments. The original file keys them by testing environment
    /// and message id, so `user_name` stays empty.
    pub fn message_tags(&self) -> Result<Vec<MessageMark>> {
        let Some(c) = self.open_tags(false)? else {
            return Ok(Vec::new());
        };
        if !table_exists(&c, "tags")? || !table_exists(&c, "message_tags")? {
            return Ok(Vec::new());
        }
        let mut st = c.prepare(
            "SELECT m.test_env, m.message_id, t.tag_name FROM message_tags m
             JOIN tags t ON t.id = m.tag_id",
        )?;
        let rows = st.query_map([], |r| {
            Ok(MessageMark {
                user_name: String::new(),
                test_env: r.get::<_, i64>(0)? != 0,
                message_id: r.get(1)?,
                value: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn set_tag(
        &self,
        _lock: &WriteLock,
        _user: &str,
        test_env: bool,
        dm_id: i64,
        name: &str,
        on: bool,
    ) -> Result<()> {
        let c = self.open_tags(true)?.unwrap();
        let env: i64 = if test_env { 1 } else { 0 };
        let tag_id: i64 = match c
            .query_row("SELECT id FROM tags WHERE tag_name = ?1", [name], |r| {
                r.get(0)
            })
            .optional()?
        {
            Some(id) => id,
            None => {
                let id = next_id(&c, "tags")?;
                c.execute(
                    "INSERT INTO tags (id, tag_name, tag_color, tag_description) VALUES (?1, ?2, NULL, NULL)",
                    params![id, name],
                )?;
                id
            }
        };
        c.execute(
            "DELETE FROM message_tags WHERE test_env = ?1 AND message_id = ?2 AND tag_id = ?3",
            params![env, dm_id, tag_id],
        )?;
        if on {
            let id = next_id(&c, "message_tags")?;
            c.execute(
                "INSERT INTO message_tags (id, test_env, message_id, tag_id) VALUES (?1, ?2, ?3, ?4)",
                params![id, env, dm_id, tag_id],
            )?;
        }
        Ok(())
    }

    /// Notes of messages; like tags they are keyed by testing environment
    /// and message id, so `user_name` stays empty.
    pub fn message_notes(&self) -> Result<Vec<MessageMark>> {
        let Some(c) = self.open_tags(false)? else {
            return Ok(Vec::new());
        };
        if !table_exists(&c, "notes")? || !table_exists(&c, "message_notes")? {
            return Ok(Vec::new());
        }
        let mut st = c.prepare(
            "SELECT m.test_env, m.message_id, n.note_content FROM message_notes m
             JOIN notes n ON n.id = m.note_id ORDER BY m.id",
        )?;
        let rows = st.query_map([], |r| {
            Ok(MessageMark {
                user_name: String::new(),
                test_env: r.get::<_, i64>(0)? != 0,
                message_id: r.get(1)?,
                value: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Replaces the note of a message; an empty text removes it.
    pub fn set_note(&self, _lock: &WriteLock, test_env: bool, dm_id: i64, text: &str) -> Result<()> {
        let c = self.open_tags(true)?.unwrap();
        c.execute_batch(NOTE_SCHEMA)?;
        let env: i64 = if test_env { 1 } else { 0 };
        let old: Vec<i64> = c
            .prepare("SELECT note_id FROM message_notes WHERE test_env = ?1 AND message_id = ?2")?
            .query_map(params![env, dm_id], |r| r.get(0))?
            .collect::<std::result::Result<_, _>>()?;
        c.execute(
            "DELETE FROM message_notes WHERE test_env = ?1 AND message_id = ?2",
            params![env, dm_id],
        )?;
        for id in old {
            c.execute("DELETE FROM notes WHERE id = ?1", [id])?;
        }
        let text = text.trim();
        if !text.is_empty() {
            let note = next_id(&c, "notes")?;
            c.execute(
                "INSERT INTO notes (id, note_content) VALUES (?1, ?2)",
                params![note, text],
            )?;
            let id = next_id(&c, "message_notes")?;
            c.execute(
                "INSERT INTO message_notes (id, test_env, message_id, note_id) VALUES (?1, ?2, ?3, ?4)",
                params![id, env, dm_id, note],
            )?;
        }
        Ok(())
    }

    pub fn drafts(&self) -> Result<Vec<Draft>> {
        let Some(c) = self.open_aux(EXTRA_DB, EXTRA_SCHEMA, false)? else {
            return Ok(Vec::new());
        };
        // Older files may lack the table.
        c.execute_batch(EXTRA_SCHEMA).ok();
        let mut st =
            c.prepare("SELECT id, user_name, content, updated FROM drafts ORDER BY updated DESC")?;
        let rows = st.query_map([], |r| {
            Ok(Draft {
                id: r.get(0)?,
                user_name: r.get(1)?,
                content: r.get(2)?,
                updated: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Saves a draft; `id` updates an existing one. Returns its id.
    pub fn save_draft(
        &self,
        _lock: &WriteLock,
        id: Option<i64>,
        user: &str,
        content: &str,
    ) -> Result<i64> {
        let c = self.open_aux(EXTRA_DB, EXTRA_SCHEMA, true)?.unwrap();
        let now = chrono::Utc::now().to_rfc3339();
        match id {
            Some(id) => {
                c.execute(
                    "UPDATE drafts SET user_name = ?2, content = ?3, updated = ?4 WHERE id = ?1",
                    params![id, user, content, now],
                )?;
                Ok(id)
            }
            None => {
                c.execute(
                    "INSERT INTO drafts (user_name, content, updated) VALUES (?1, ?2, ?3)",
                    params![user, content, now],
                )?;
                Ok(c.last_insert_rowid())
            }
        }
    }

    pub fn delete_draft(&self, _lock: &WriteLock, id: i64) -> Result<()> {
        let c = self.open_aux(EXTRA_DB, EXTRA_SCHEMA, true)?.unwrap();
        c.execute("DELETE FROM drafts WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn deadlines(&self) -> Result<Vec<MessageMark>> {
        let Some(c) = self.open_aux(EXTRA_DB, EXTRA_SCHEMA, false)? else {
            return Ok(Vec::new());
        };
        let mut st = c.prepare("SELECT user_name, message_id, deadline FROM deadlines")?;
        let rows = st.query_map([], |r| {
            Ok(MessageMark {
                user_name: r.get(0)?,
                test_env: false,
                message_id: r.get(1)?,
                value: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Sets the deadline of a message (`YYYY-MM-DD`), or clears it with `None`.
    pub fn set_deadline(
        &self,
        _lock: &WriteLock,
        user: &str,
        dm_id: i64,
        deadline: Option<&str>,
    ) -> Result<()> {
        let c = self.open_aux(EXTRA_DB, EXTRA_SCHEMA, true)?.unwrap();
        match deadline {
            Some(d) => c.execute(
                "INSERT INTO deadlines (user_name, message_id, deadline) VALUES (?1, ?2, ?3)
                 ON CONFLICT (user_name, message_id) DO UPDATE SET deadline = excluded.deadline",
                params![user, dm_id, d],
            )?,
            None => c.execute(
                "DELETE FROM deadlines WHERE user_name = ?1 AND message_id = ?2",
                params![user, dm_id],
            )?,
        };
        Ok(())
    }
}

fn table_exists(c: &Connection, name: &str) -> Result<bool> {
    let n: i64 = c.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [name],
        |r| r.get(0),
    )?;
    Ok(n > 0)
}

fn next_id(c: &Connection, table: &str) -> Result<i64> {
    let sql = format!("SELECT COALESCE(MAX(id), 0) + 1 FROM {table}");
    Ok(c.query_row(&sql, [], |r| r.get(0))?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::legacy::lock;

    #[test]
    fn tags_and_deadlines_round_trip() {
        let dir = std::env::temp_dir().join(format!("datovka-extra-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let s = LegacyStore::new(&dir);
        assert!(s.tags().unwrap().is_empty());
        let lock::Acquire::Acquired(l) = lock::acquire(&dir, "t").unwrap() else {
            panic!()
        };
        s.set_tag(&l, "abc", false, 1, "Spor", true).unwrap();
        s.set_tag(&l, "abc", true, 1, "Spor", true).unwrap();
        s.set_tag(&l, "abc", false, 2, "Spor", true).unwrap();
        s.set_tag(&l, "abc", false, 2, "Spor", false).unwrap();
        let marks = s.message_tags().unwrap();
        assert_eq!(marks.len(), 2);
        assert!(marks.iter().any(|m| m.message_id == 1 && m.test_env));
        assert!(marks.iter().any(|m| m.message_id == 1 && !m.test_env));
        assert!(s.message_notes().unwrap().is_empty());
        s.set_note(&l, false, 1, "Zavolat na úřad").unwrap();
        s.set_note(&l, false, 1, " Zavoláno, čekáme ").unwrap();
        s.set_note(&l, true, 1, "test").unwrap();
        let notes = s.message_notes().unwrap();
        assert_eq!(notes.len(), 2);
        assert!(notes.iter().any(|n| !n.test_env && n.value == "Zavoláno, čekáme"));
        s.set_note(&l, true, 1, "").unwrap();
        assert_eq!(s.message_notes().unwrap().len(), 1);
        s.set_deadline(&l, "abc", 1, Some("2026-11-12")).unwrap();
        s.set_deadline(&l, "abc", 1, Some("2026-11-15")).unwrap();
        assert_eq!(s.deadlines().unwrap()[0].value, "2026-11-15");
        s.set_deadline(&l, "abc", 1, None).unwrap();
        assert!(s.deadlines().unwrap().is_empty());
        let id = s.save_draft(&l, None, "abc", "{}").unwrap();
        s.save_draft(&l, Some(id), "abc", r#"{"a":1}"#).unwrap();
        assert_eq!(s.drafts().unwrap()[0].content, r#"{"a":1}"#);
        s.delete_draft(&l, id).unwrap();
        assert!(s.drafts().unwrap().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
