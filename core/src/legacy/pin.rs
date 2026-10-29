//! PIN protection of passwords in `dsgui.conf`, compatible with the original
//! Datovka (`src/datovka_shared/crypto/crypto_pin*.c*`, `crypto_pwd.c`,
//! `settings/pin.cpp`, `settings/account.cpp`).
//!
//! * PIN verifier (`[security]` `pin_alg`, `pin_salt`, `pin_code`):
//!   `pin_code = PBKDF2-HMAC-SHA256(utf8(pin), pin_salt, 1000 iterations, 64 bytes)`,
//!   `pin_salt` is 64 random bytes, `pin_alg = "PBKDF2-HMAC-SHA-256-64"`.
//! * Password (`[credentialsN]` `pwd_alg`, `pwd_salt`, `pwd_iv`, `pwd_code`):
//!   `key = PBKDF2-HMAC-SHA256(utf8(pin), pwd_salt, 1000, 32 bytes)`,
//!   `pwd_code = AES-256-CBC(key, pwd_iv, utf8(password))` with PKCS#7 padding,
//!   `pwd_salt` is 32 random bytes, `pwd_iv` 16 random bytes,
//!   `pwd_alg = "AES-256-CBC"`.
//!
//! All binary values are stored as standard base64 (with padding).

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use base64::Engine;
use sha2::Sha256;

use crate::error::{Error, Result};

/// Name of the PIN verifier algorithm (`pin_alg`).
pub const PIN_ALG: &str = "PBKDF2-HMAC-SHA-256-64";
/// Name of the password cipher (`pwd_alg`).
pub const PWD_ALG: &str = "AES-256-CBC";

const PBKDF2_ITER: u32 = 1000;
const PIN_CODE_LEN: usize = 64;
const KEY_LEN: usize = 32;
const IV_LEN: usize = 16;

type Aes256CbcEnc = cbc::Encryptor<aes::Aes256>;
type Aes256CbcDec = cbc::Decryptor<aes::Aes256>;

fn err(text: impl Into<String>) -> Error {
    Error::Isds {
        code: "pin".into(),
        text: text.into(),
    }
}

fn b64_decode(v: &str) -> Result<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
        .decode(v.trim())
        .map_err(|e| err(format!("neplatné base64: {e}")))
}

fn b64_encode(v: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(v)
}

fn random_bytes(len: usize) -> Result<Vec<u8>> {
    let mut buf = vec![0u8; len];
    getrandom::getrandom(&mut buf).map_err(|e| err(format!("generátor náhody: {e}")))?;
    Ok(buf)
}

/// `computePinCode()` of the original: PBKDF2-HMAC-SHA256, 1000 iterations.
fn pbkdf2(pin: &str, salt: &[u8], out_len: usize) -> Vec<u8> {
    let mut out = vec![0u8; out_len];
    pbkdf2::pbkdf2_hmac::<Sha256>(pin.as_bytes(), salt, PBKDF2_ITER, &mut out);
    out
}

/// Strips the quotes `QSettings` puts around some INI values.
fn ini_value(v: &str) -> &str {
    let v = v.trim();
    v.strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .unwrap_or(v)
}

/// PIN verifier from the `[security]` section of `dsgui.conf`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PinSettings {
    pub alg: String,
    pub salt_b64: String,
    pub code_b64: String,
}

impl PinSettings {
    /// Reads `pin_alg`, `pin_salt` and `pin_code` from `[security]`.
    pub fn parse(conf_text: &str) -> Self {
        let mut out = Self::default();
        let mut in_security = false;
        for line in conf_text.lines() {
            let line = line.trim();
            if let Some(s) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                in_security = s == "security";
                continue;
            }
            if !in_security {
                continue;
            }
            let Some((k, v)) = line.split_once('=') else {
                continue;
            };
            let v = ini_value(v).to_string();
            match k.trim() {
                "pin_alg" => out.alg = v,
                "pin_salt" => out.salt_b64 = v,
                "pin_code" => out.code_b64 = v,
                _ => {}
            }
        }
        out
    }

    /// Same as `PinSettings::pinConfigured()` of the original.
    pub fn configured(&self) -> bool {
        !self.alg.is_empty() && !self.salt_b64.is_empty() && !self.code_b64.is_empty()
    }

    pub fn verify(&self, pin: &str) -> Result<bool> {
        if !self.configured() {
            return Err(err("PIN není nastaven"));
        }
        if pin.is_empty() || self.alg != PIN_ALG {
            return Ok(false);
        }
        let salt = b64_decode(&self.salt_b64)?;
        let code = b64_decode(&self.code_b64)?;
        Ok(pbkdf2(pin, &salt, PIN_CODE_LEN) == code)
    }

    /// New verifier for `pin` (random 64-byte salt), as `updatePinValue()`.
    pub fn new_for_pin(pin: &str) -> Result<Self> {
        if pin.is_empty() {
            return Err(err("prázdný PIN"));
        }
        let salt = random_bytes(PIN_CODE_LEN)?;
        Ok(Self {
            alg: PIN_ALG.into(),
            salt_b64: b64_encode(&salt),
            code_b64: b64_encode(&pbkdf2(pin, &salt, PIN_CODE_LEN)),
        })
    }
}

/// True when `dsgui.conf` contains a PIN verifier.
pub fn pin_configured(conf_text: &str) -> bool {
    PinSettings::parse(conf_text).configured()
}

/// Checks `pin` against the verifier in `[security]` of `dsgui.conf`.
/// Errors when no PIN is configured.
pub fn verify_pin(conf_text: &str, pin: &str) -> Result<bool> {
    PinSettings::parse(conf_text).verify(pin)
}

/// Decrypts a password stored as `pwd_alg`, `pwd_salt`, `pwd_iv`, `pwd_code`
/// (raw base64 values from `dsgui.conf`). An empty IV means a zero IV, as
/// OpenSSL does with a NULL IV.
pub fn decrypt_password(
    alg: &str,
    salt_b64: &str,
    iv_b64: &str,
    code_b64: &str,
    pin: &str,
) -> Result<String> {
    if pin.is_empty() {
        return Err(err("prázdný PIN"));
    }
    if alg != PWD_ALG {
        return Err(err(format!("nepodporovaný algoritmus hesla: {alg}")));
    }
    let salt = b64_decode(salt_b64)?;
    let iv = b64_decode(iv_b64)?;
    let code = b64_decode(code_b64)?;
    if salt.is_empty() || code.is_empty() {
        return Err(err("chybí sůl nebo zašifrované heslo"));
    }
    if !iv.is_empty() && iv.len() < IV_LEN {
        return Err(err("neplatný inicializační vektor"));
    }
    let mut iv_arr = [0u8; IV_LEN];
    if !iv.is_empty() {
        iv_arr.copy_from_slice(&iv[..IV_LEN]);
    }
    let key = pbkdf2(pin, &salt, KEY_LEN);
    let plain = Aes256CbcDec::new_from_slices(&key, &iv_arr)
        .map_err(|e| err(e.to_string()))?
        .decrypt_padded_vec_mut::<Pkcs7>(&code)
        .map_err(|_| err("heslo nelze dešifrovat (špatný PIN?)"))?;
    if plain.is_empty() {
        return Err(err("heslo nelze dešifrovat (špatný PIN?)"));
    }
    String::from_utf8(plain).map_err(|_| err("heslo nelze dešifrovat (špatný PIN?)"))
}

/// Values to be written as `pwd_alg`, `pwd_salt`, `pwd_iv`, `pwd_code`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncryptedPassword {
    pub alg: String,
    pub salt_b64: String,
    pub iv_b64: String,
    pub code_b64: String,
}

/// Encrypts with the given salt (≥ 32 bytes) and IV (≥ 16 bytes), like
/// `storeEncryptedPwd()` does when it reuses existing values.
pub fn encrypt_password_with(
    password: &str,
    pin: &str,
    salt: &[u8],
    iv: &[u8],
) -> Result<EncryptedPassword> {
    if password.is_empty() || pin.is_empty() {
        return Err(err("prázdné heslo nebo PIN"));
    }
    if salt.len() < KEY_LEN || iv.len() < IV_LEN {
        return Err(err("příliš krátká sůl nebo inicializační vektor"));
    }
    let key = pbkdf2(pin, salt, KEY_LEN);
    let code = Aes256CbcEnc::new_from_slices(&key, &iv[..IV_LEN])
        .map_err(|e| err(e.to_string()))?
        .encrypt_padded_vec_mut::<Pkcs7>(password.as_bytes());
    Ok(EncryptedPassword {
        alg: PWD_ALG.into(),
        salt_b64: b64_encode(salt),
        iv_b64: b64_encode(iv),
        code_b64: b64_encode(&code),
    })
}

/// Encrypts with a fresh random 32-byte salt and 16-byte IV.
/// Returns `(pwd_alg, pwd_salt, pwd_iv, pwd_code)`.
pub fn encrypt_password(password: &str, pin: &str) -> Result<(String, String, String, String)> {
    let e = encrypt_password_with(
        password,
        pin,
        &random_bytes(KEY_LEN)?,
        &random_bytes(IV_LEN)?,
    )?;
    Ok((e.alg, e.salt_b64, e.iv_b64, e.code_b64))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors computed independently with Python `hashlib.pbkdf2_hmac` and
    // `openssl enc -aes-256-cbc -K <key> -iv <iv>`.
    const SALT: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="; // 0..32
    const IV: &str = "ZGVmZ2hpamtsbW5vcHFycw=="; // 100..116
    const CODE: &str = "Z75iqSyCrk9m2hZ+ZVSi230MZDrLYXTNVC/I3BY/3LU=";
    const PASSWORD: &str = "Tajné heslo 123";

    #[test]
    fn decrypts_known_vector() {
        assert_eq!(
            decrypt_password(PWD_ALG, SALT, IV, CODE, "1234").unwrap(),
            PASSWORD
        );
        assert!(decrypt_password(PWD_ALG, SALT, IV, CODE, "1235").is_err());
    }

    #[test]
    fn encrypts_known_vector() {
        let salt: Vec<u8> = (0..32).collect();
        let iv: Vec<u8> = (100..116).collect();
        let e = encrypt_password_with(PASSWORD, "1234", &salt, &iv).unwrap();
        assert_eq!(e.alg, PWD_ALG);
        assert_eq!(e.salt_b64, SALT);
        assert_eq!(e.iv_b64, IV);
        assert_eq!(e.code_b64, CODE);
    }

    #[test]
    fn round_trip() {
        for pwd in ["x", "0123456789abcdef", "Heslo s diakritikou ěščřžýáíé!"] {
            let (alg, salt, iv, code) = encrypt_password(pwd, "9876").unwrap();
            assert_eq!(b64_decode(&salt).unwrap().len(), 32);
            assert_eq!(b64_decode(&iv).unwrap().len(), 16);
            assert_eq!(
                decrypt_password(&alg, &salt, &iv, &code, "9876").unwrap(),
                pwd
            );
        }
    }

    #[test]
    fn verifies_pin() {
        let salt: String = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+Pw==".into();
        let conf = format!(
            "[credentials]\nusername=a\n\n[security]\npin_alg={PIN_ALG}\npin_salt={salt}\n\
             pin_code=pjaqw0hKFgkj/NeCJoHoT57kbq7m04BF6a4u+icBK0QvtPVRMfPgJircWuUV9e0pUEg41l0ofsZjvu19LWyIzw==\n"
        );
        assert!(pin_configured(&conf));
        assert!(verify_pin(&conf, "PÍN1").unwrap());
        assert!(!verify_pin(&conf, "PIN1").unwrap());
        assert!(verify_pin("[security]\n", "1").is_err());

        let fresh = PinSettings::new_for_pin("4321").unwrap();
        assert!(fresh.verify("4321").unwrap());
        assert!(!fresh.verify("1234").unwrap());
    }
}
