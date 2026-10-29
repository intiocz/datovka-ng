//! Box passwords in the system store of this device: Keychain on macOS and
//! iOS, Credential Manager on Windows, Secret Service on Linux. They never go
//! into `dsgui.conf`, so the shared archive (iCloud, other computers) does not
//! carry them. The original Datovka keeps its own base64 passwords in
//! `dsgui.conf`; those are read as before.

use crate::error::{Error, Result};

const SERVICE: &str = "Datovka NG";

fn key(username: &str, test_env: bool) -> String {
    if test_env {
        format!("{username} (test)")
    } else {
        username.to_string()
    }
}

#[cfg_attr(test, allow(dead_code))]
fn fail(e: impl std::fmt::Display) -> Error {
    Error::Isds {
        code: "keychain".into(),
        text: format!("heslo se nepodařilo uložit do úložiště hesel: {e}"),
    }
}

/// The stored password, `None` when there is none or the store is unavailable.
pub fn password(username: &str, test_env: bool) -> Option<String> {
    store::get(&key(username, test_env))
}

pub fn set_password(username: &str, test_env: bool, password: &str) -> Result<()> {
    store::set(&key(username, test_env), password)
}

/// Forgets the password; a missing one is not an error.
pub fn delete(username: &str, test_env: bool) -> Result<()> {
    store::delete(&key(username, test_env))
}

/// Other secrets of this device, such as the assistant's API key. Their
/// names start with `app:` so they never meet a box username.
pub fn app_secret(name: &str) -> Option<String> {
    store::get(&format!("app:{name}"))
}

/// Stores the secret; an empty value deletes it.
pub fn set_app_secret(name: &str, value: &str) -> Result<()> {
    if value.is_empty() {
        store::delete(&format!("app:{name}"))
    } else {
        store::set(&format!("app:{name}"), value)
    }
}

#[cfg(all(not(test), not(target_os = "android")))]
mod store {
    use super::*;

    fn entry(account: &str) -> Result<keyring::Entry> {
        keyring::Entry::new(SERVICE, account).map_err(fail)
    }

    pub fn get(account: &str) -> Option<String> {
        entry(account).ok()?.get_password().ok()
    }

    pub fn set(account: &str, password: &str) -> Result<()> {
        entry(account)?.set_password(password).map_err(fail)
    }

    pub fn delete(account: &str) -> Result<()> {
        match entry(account)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(fail(e)),
        }
    }
}

/// Android has no store wired in yet: nothing is saved, the user types the
/// password at login.
#[cfg(all(not(test), target_os = "android"))]
mod store {
    use super::*;

    pub fn get(_: &str) -> Option<String> {
        let _ = SERVICE;
        None
    }

    pub fn set(_: &str, _: &str) -> Result<()> {
        Err(fail("na Androidu zatím není k dispozici"))
    }

    pub fn delete(_: &str) -> Result<()> {
        Ok(())
    }
}

/// Tests keep passwords in memory and never touch the real store.
#[cfg(test)]
mod store {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    static MEM: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

    pub fn get(account: &str) -> Option<String> {
        let _ = SERVICE;
        MEM.lock().unwrap().as_ref()?.get(account).cloned()
    }

    pub fn set(account: &str, password: &str) -> Result<()> {
        MEM.lock()
            .unwrap()
            .get_or_insert_with(HashMap::new)
            .insert(account.into(), password.into());
        Ok(())
    }

    pub fn delete(account: &str) -> Result<()> {
        if let Some(m) = MEM.lock().unwrap().as_mut() {
            m.remove(account);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_production_and_test_boxes_apart() {
        set_password("sec1", false, "ostre").unwrap();
        set_password("sec1", true, "testovaci").unwrap();
        assert_eq!(password("sec1", false).as_deref(), Some("ostre"));
        assert_eq!(password("sec1", true).as_deref(), Some("testovaci"));
        delete("sec1", false).unwrap();
        delete("sec1", false).unwrap();
        assert_eq!(password("sec1", false), None);
        assert_eq!(password("sec1", true).as_deref(), Some("testovaci"));
    }

    #[test]
    fn app_secrets_stay_apart_from_boxes() {
        set_password("anthropic-api-key", false, "heslo").unwrap();
        set_app_secret("anthropic-api-key", "sk-ant-x").unwrap();
        assert_eq!(app_secret("anthropic-api-key").as_deref(), Some("sk-ant-x"));
        assert_eq!(password("anthropic-api-key", false).as_deref(), Some("heslo"));
        set_app_secret("anthropic-api-key", "").unwrap();
        assert_eq!(app_secret("anthropic-api-key"), None);
    }
}
