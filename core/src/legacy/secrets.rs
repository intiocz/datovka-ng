//! Box passwords in the system store of this device: Keychain on macOS and
//! iOS, Credential Manager on Windows, Secret Service on Linux, and on
//! Android a file encrypted with a key from the Android Keystore. They never go
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
        let first = entry(account)?.set_password(password);
        // Linux without a default keyring (e.g. automatic login): create it
        // and try once more.
        #[cfg(target_os = "linux")]
        if first.is_err() && create_keyring()? {
            return entry(account)?.set_password(password).map_err(fail);
        }
        first.map_err(fail)
    }

    /// Creates the default Secret Service collection when there is none;
    /// the system asks for a password for it, as for any other app. False
    /// when it already exists, so the failure was something else.
    #[cfg(target_os = "linux")]
    fn create_keyring() -> Result<bool> {
        use dbus_secret_service::{EncryptionType, Error as SsError, SecretService};
        // Two minutes to answer the system dialog.
        let ss = SecretService::connect_with_max_prompt_timeout(EncryptionType::Dh, 120)
            .map_err(fail)?;
        match ss.get_default_collection() {
            Ok(_) => Ok(false),
            Err(SsError::NoResult) => match ss.create_collection("Login", "default") {
                Ok(_) => Ok(true),
                Err(SsError::Prompt) => Err(Error::Isds {
                    code: "keychain".into(),
                    text: "heslo se neuložilo: systém se ptal na heslo k nové klíčence \
                           a dotaz se zavřel. Zkuste to znovu a heslo klíčence zvolte."
                        .into(),
                }),
                Err(e) => Err(fail(e)),
            },
            Err(e) => Err(fail(e)),
        }
    }

    pub fn delete(account: &str) -> Result<()> {
        match entry(account)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(fail(e)),
        }
    }
}

/// Android: an encrypted file in the app's own storage, with a key the app
/// keeps in the Android Keystore and hands over at start ([`use_file_store`]).
#[cfg(all(not(test), target_os = "android"))]
mod store {
    use super::*;
    use crate::legacy::sealed::FileStore;
    use std::sync::Mutex;

    pub(super) static FILE: Mutex<Option<FileStore>> = Mutex::new(None);

    pub fn get(account: &str) -> Option<String> {
        let _ = SERVICE;
        FILE.lock().unwrap().as_ref()?.get(account)
    }

    pub fn set(account: &str, password: &str) -> Result<()> {
        match FILE.lock().unwrap().as_ref() {
            Some(f) => f.set(account, password),
            None => Err(fail("úložiště klíčů telefonu není dostupné")),
        }
    }

    pub fn delete(account: &str) -> Result<()> {
        match FILE.lock().unwrap().as_ref() {
            Some(f) => f.delete(account),
            None => Ok(()),
        }
    }
}

/// Where the passwords of this device are kept on Android; see [`store`].
#[cfg(target_os = "android")]
pub fn use_file_store(key: [u8; 32], path: std::path::PathBuf) {
    #[cfg(not(test))]
    {
        *store::FILE.lock().unwrap() = Some(crate::legacy::sealed::FileStore { key, path });
    }
    #[cfg(test)]
    let _ = (key, path);
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
