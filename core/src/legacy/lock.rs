//! Cross-device write lock for a synced data folder.
//!
//! SQLite files synced by iCloud Drive get corrupted when two devices write at
//! once. Reading is always allowed. A write holds this lock only while it
//! runs, then releases it, so a phone and several computers can use the same
//! archive together. A lock with no heartbeat for [`STALE_AFTER`] is taken by
//! the next write (the holder crashed, or iCloud delivered an old copy).

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::error::Result;

pub const LOCK_FILE: &str = ".datovka-zamek.json";
pub const STALE_AFTER: Duration = Duration::minutes(2);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LockInfo {
    pub device: String,
    pub app: String,
    pub heartbeat: DateTime<Utc>,
    /// Process that wrote the lock. Missing in older files.
    #[serde(default)]
    pub pid: u32,
}

impl LockInfo {
    pub fn is_stale(&self, now: DateTime<Utc>) -> bool {
        now - self.heartbeat > STALE_AFTER
    }

    pub fn stale_now(&self) -> bool {
        self.is_stale(Utc::now())
    }
}

/// Proof of holding the lock; required by every write. Dropped at the end of
/// the write, which releases the file when this process has no other write.
#[derive(Debug)]
pub struct WriteLock {
    path: PathBuf,
    dir: PathBuf,
    device: String,
    pid: u32,
}

pub enum Acquire {
    Acquired(WriteLock),
    /// Another device is in the middle of a write.
    HeldBy(LockInfo),
}

struct Hold {
    device: String,
    pid: u32,
    count: usize,
}

fn holds() -> &'static Mutex<HashMap<PathBuf, Hold>> {
    static H: OnceLock<Mutex<HashMap<PathBuf, Hold>>> = OnceLock::new();
    H.get_or_init(|| Mutex::new(HashMap::new()))
}

fn read(path: &Path) -> Option<LockInfo> {
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn write(path: &Path, info: &LockInfo) -> Result<()> {
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    fs::write(&tmp, serde_json::to_vec_pretty(info)?)?;
    fs::rename(tmp, path)?;
    Ok(())
}

pub fn peek(dir: &Path) -> Option<LockInfo> {
    read(&dir.join(LOCK_FILE))
}

/// Takes the lock when it is free, already ours, or stale.
/// A fresh lock of another device is left alone.
pub fn acquire(dir: &Path, device: &str) -> Result<Acquire> {
    let dir = dir.to_path_buf();
    let path = dir.join(LOCK_FILE);
    let pid = std::process::id();
    let mut map = holds().lock().unwrap();
    if let Some(h) = map.get_mut(&dir) {
        if h.device == device && h.pid == pid {
            write_ours(&path, device, pid)?;
            h.count += 1;
            return Ok(Acquire::Acquired(WriteLock {
                path,
                dir,
                device: device.to_string(),
                pid,
            }));
        }
    }
    if let Some(cur) = read(&path) {
        let same = cur.device == device && (cur.pid == 0 || cur.pid == pid);
        if !same && !cur.is_stale(Utc::now()) {
            return Ok(Acquire::HeldBy(cur));
        }
    }
    write_ours(&path, device, pid)?;
    map.insert(
        dir.clone(),
        Hold {
            device: device.to_string(),
            pid,
            count: 1,
        },
    );
    Ok(Acquire::Acquired(WriteLock {
        path,
        dir,
        device: device.to_string(),
        pid,
    }))
}

/// Like [`acquire`], but waits while another device is writing.
pub fn acquire_wait(dir: &Path, device: &str, timeout: StdDuration) -> Result<Acquire> {
    let start = std::time::Instant::now();
    loop {
        match acquire(dir, device)? {
            Acquire::Acquired(l) => return Ok(Acquire::Acquired(l)),
            Acquire::HeldBy(info) if start.elapsed() >= timeout => {
                return Ok(Acquire::HeldBy(info));
            }
            Acquire::HeldBy(_) => std::thread::sleep(StdDuration::from_millis(400)),
        }
    }
}

/// Replaces whoever holds the lock. Used when the user asks to take over.
pub fn take(dir: &Path, device: &str) -> Result<WriteLock> {
    let dir = dir.to_path_buf();
    let path = dir.join(LOCK_FILE);
    let pid = std::process::id();
    write_ours(&path, device, pid)?;
    let mut map = holds().lock().unwrap();
    let count = map
        .get(&dir)
        .filter(|h| h.device == device && h.pid == pid)
        .map(|h| h.count)
        .unwrap_or(0)
        + 1;
    map.insert(
        dir.clone(),
        Hold {
            device: device.to_string(),
            pid,
            count,
        },
    );
    Ok(WriteLock {
        path,
        dir,
        device: device.to_string(),
        pid,
    })
}

fn write_ours(path: &Path, device: &str, pid: u32) -> Result<()> {
    write(
        path,
        &LockInfo {
            device: device.to_string(),
            app: "datovka-next".into(),
            heartbeat: Utc::now(),
            pid,
        },
    )
}

impl WriteLock {
    /// Refreshes the heartbeat; call periodically (e.g. every minute).
    pub fn refresh(&self) -> Result<()> {
        write_ours(&self.path, &self.device, self.pid)
    }

    pub fn release(self) -> Result<()> {
        drop(self);
        Ok(())
    }
}

impl Drop for WriteLock {
    fn drop(&mut self) {
        let mut map = holds().lock().unwrap();
        let Some(h) = map.get_mut(&self.dir) else {
            return;
        };
        if h.device != self.device || h.pid != self.pid {
            return;
        }
        h.count = h.count.saturating_sub(1);
        if h.count > 0 {
            return;
        }
        map.remove(&self.dir);
        if read(&self.path).is_some_and(|i| i.device == self.device && (i.pid == 0 || i.pid == self.pid))
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn second_device_is_refused_until_release() {
        let dir = std::env::temp_dir().join(format!("datovka-lock-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let Acquire::Acquired(l) = acquire(&dir, "mac").unwrap() else {
            panic!("first acquire failed")
        };
        assert!(matches!(acquire(&dir, "pc").unwrap(), Acquire::HeldBy(i) if i.device == "mac"));
        assert!(matches!(
            acquire(&dir, "mac").unwrap(),
            Acquire::Acquired(_)
        ));
        l.release().unwrap();
        assert!(matches!(acquire(&dir, "pc").unwrap(), Acquire::Acquired(_)));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn stale_lock_is_taken_by_the_next_write() {
        let dir = std::env::temp_dir().join(format!("datovka-lock-stale-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join(LOCK_FILE),
            r#"{"device":"mac","app":"datovka-next","heartbeat":"2000-01-01T00:00:00Z"}"#,
        )
        .unwrap();
        assert!(peek(&dir).unwrap().is_stale(Utc::now()));
        let Acquire::Acquired(l) = acquire(&dir, "pc").unwrap() else {
            panic!("stale lock was not taken")
        };
        assert_eq!(peek(&dir).unwrap().device, "pc");
        l.release().unwrap();
        assert!(peek(&dir).is_none());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn waiter_proceeds_after_the_writer_finishes() {
        let dir = std::env::temp_dir().join(format!("datovka-lock-wait-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let Acquire::Acquired(l) = acquire(&dir, "mac").unwrap() else {
            panic!("first acquire failed")
        };
        let held = acquire_wait(&dir, "pc", StdDuration::from_millis(300)).unwrap();
        assert!(matches!(held, Acquire::HeldBy(i) if i.device == "mac"));
        drop(l);
        assert!(matches!(
            acquire(&dir, "phone").unwrap(),
            Acquire::Acquired(_)
        ));
        fs::remove_dir_all(dir).unwrap();
    }
}
