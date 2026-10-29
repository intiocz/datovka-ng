//! Secrets in one encrypted file, for systems where the core cannot reach
//! the system store itself (Android). The key comes from the app, which
//! keeps it in the system key store; the file lives in the app's own
//! storage, never in the shared archive.
//!
//! Format: 16-byte IV, AES-256-CBC ciphertext of a JSON map, and an
//! HMAC-SHA256 over IV and ciphertext. Encryption and MAC keys are derived
//! from the app key.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use hmac::{Hmac, Mac};
use sha2::Sha256;

use crate::error::{Error, Result};

type Enc = cbc::Encryptor<aes::Aes256>;
type Dec = cbc::Decryptor<aes::Aes256>;

fn err(text: impl Into<String>) -> Error {
    Error::Isds {
        code: "keychain".into(),
        text: text.into(),
    }
}

fn derive(key: &[u8; 32], label: &[u8]) -> [u8; 32] {
    let mut m = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("any key length");
    m.update(label);
    m.finalize().into_bytes().into()
}

fn mac(key: &[u8; 32], data: &[u8]) -> Hmac<Sha256> {
    let mut m = <Hmac<Sha256> as Mac>::new_from_slice(&derive(key, b"mac")).expect("any key length");
    m.update(data);
    m
}

pub fn seal(key: &[u8; 32], map: &BTreeMap<String, String>) -> Result<Vec<u8>> {
    let mut iv = [0u8; 16];
    getrandom::getrandom(&mut iv).map_err(|e| err(format!("generátor náhody: {e}")))?;
    let plain = serde_json::to_vec(map)?;
    let mut out = iv.to_vec();
    out.extend(Enc::new(&derive(key, b"enc").into(), &iv.into()).encrypt_padded_vec_mut::<Pkcs7>(&plain));
    let tag = mac(key, &out).finalize().into_bytes();
    out.extend_from_slice(&tag);
    Ok(out)
}

pub fn open(key: &[u8; 32], data: &[u8]) -> Result<BTreeMap<String, String>> {
    if data.len() < 16 + 16 + 32 {
        return Err(err("soubor s hesly je poškozený"));
    }
    let (body, tag) = data.split_at(data.len() - 32);
    mac(key, body)
        .verify_slice(tag)
        .map_err(|_| err("soubor s hesly nepatří k tomuto klíči nebo je poškozený"))?;
    let (iv, cipher) = body.split_at(16);
    let iv: [u8; 16] = iv.try_into().expect("16 bytes");
    let plain = Dec::new(&derive(key, b"enc").into(), &iv.into())
        .decrypt_padded_vec_mut::<Pkcs7>(cipher)
        .map_err(|_| err("soubor s hesly je poškozený"))?;
    Ok(serde_json::from_slice(&plain)?)
}

/// The secrets file with its key.
pub struct FileStore {
    pub key: [u8; 32],
    pub path: PathBuf,
}

impl FileStore {
    fn load(&self) -> BTreeMap<String, String> {
        std::fs::read(&self.path)
            .ok()
            .and_then(|d| open(&self.key, &d).ok())
            .unwrap_or_default()
    }

    fn save(&self, map: &BTreeMap<String, String>) -> Result<()> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        // Write aside and rename, so a crash never leaves half a file.
        let tmp = self.path.with_extension("tmp");
        std::fs::write(&tmp, seal(&self.key, map)?)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }

    pub fn get(&self, name: &str) -> Option<String> {
        self.load().get(name).cloned()
    }

    pub fn set(&self, name: &str, value: &str) -> Result<()> {
        let mut map = self.load();
        map.insert(name.into(), value.into());
        self.save(&map)
    }

    pub fn delete(&self, name: &str) -> Result<()> {
        let mut map = self.load();
        if map.remove(name).is_some() {
            self.save(&map)?;
        }
        Ok(())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passwords_round_trip_and_a_wrong_key_reads_nothing() {
        let dir = std::env::temp_dir().join(format!("datovka-sealed-{}", std::process::id()));
        let store = FileStore {
            key: [7; 32],
            path: dir.join("hesla.bin"),
        };
        assert_eq!(store.get("abc123"), None);
        store.set("abc123", "tajne heslo").unwrap();
        store.set("app:anthropic-api-key", "sk-x").unwrap();
        assert_eq!(store.get("abc123").as_deref(), Some("tajne heslo"));
        let raw = std::fs::read(store.path()).unwrap();
        assert!(!raw.windows(5).any(|w| w == b"tajne"), "stored encrypted");

        let other = FileStore {
            key: [8; 32],
            path: store.path.clone(),
        };
        assert_eq!(other.get("abc123"), None);
        let mut broken = raw.clone();
        broken[20] ^= 1;
        assert!(open(&store.key, &broken).is_err());

        store.delete("abc123").unwrap();
        assert_eq!(store.get("abc123"), None);
        assert_eq!(store.get("app:anthropic-api-key").as_deref(), Some("sk-x"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
