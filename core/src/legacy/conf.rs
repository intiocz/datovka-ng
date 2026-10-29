//! `dsgui.conf` of the original Datovka: account list with credentials.

use std::path::Path;

use base64::Engine;
use serde::Serialize;
use serde_json::{json, Value};

use crate::error::Result;
use crate::isds::LoginMethod;

#[derive(Debug, Clone, Default, Serialize)]
pub struct LegacyAccount {
    /// Section name, e.g. `credentials2`; keeps the original order.
    pub section: String,
    pub name: String,
    pub username: String,
    pub login: LoginMethod,
    pub test_env: bool,
    pub sync_with_all: bool,
    #[serde(skip)]
    pub password: Option<String>,
    #[serde(skip)]
    pub mep_token: Option<String>,
    /// PKCS#12 file of a certificate login (`p12file`).
    pub p12_file: Option<String>,
    /// Password is stored encrypted with a PIN (`password_alg` etc.).
    pub pin_protected: bool,
    /// Raw `pwd_alg` value (e.g. `AES-256-CBC`).
    #[serde(skip)]
    pub pwd_alg: Option<String>,
    /// Raw base64 `pwd_salt`.
    #[serde(skip)]
    pub pwd_salt: Option<String>,
    /// Raw base64 `pwd_iv`.
    #[serde(skip)]
    pub pwd_iv: Option<String>,
    /// Raw base64 `pwd_code` (encrypted password).
    #[serde(skip)]
    pub pwd_code: Option<String>,
    /// `database_dir`: the original app can keep the message databases of
    /// an account in another folder. Empty means the archive folder.
    #[serde(skip)]
    pub db_dir: Option<String>,
}

impl LegacyAccount {
    pub fn has_password(&self) -> bool {
        self.password.is_some()
    }

    /// Password decrypted with `pin` when it is stored PIN-protected;
    /// `Ok(None)` when no encrypted password is stored.
    pub fn password_with_pin(&self, pin: &str) -> Result<Option<String>> {
        let Some(code) = self.pwd_code.as_deref().filter(|c| !c.is_empty()) else {
            return Ok(None);
        };
        super::pin::decrypt_password(
            self.pwd_alg.as_deref().unwrap_or_default(),
            self.pwd_salt.as_deref().unwrap_or_default(),
            self.pwd_iv.as_deref().unwrap_or_default(),
            code,
            pin,
        )
        .map(Some)
    }
}

fn login_method(v: &str) -> LoginMethod {
    match v {
        "username" => LoginMethod::Password,
        "certificate" | "user_certificate" => LoginMethod::Certificate,
        "hotp" => LoginMethod::PasswordHotp,
        "totp" => LoginMethod::PasswordTotp,
        "mep" => LoginMethod::MobileKey,
        _ => LoginMethod::Password,
    }
}

fn b64(v: &str) -> Option<String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(v.trim())
        .ok()?;
    String::from_utf8(bytes).ok().filter(|s| !s.is_empty())
}

/// A string value as `QSettings` writes it: in quotes when it holds special
/// characters, with `\\` and `\"` escaped.
fn ini_string(v: &str) -> String {
    let v = v
        .strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .unwrap_or(v);
    let mut out = String::new();
    let mut chars = v.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => out.extend(chars.next()),
            c => out.push(c),
        }
    }
    out
}

/// Parses the INI file; unknown keys are ignored.
pub fn parse(text: &str) -> Vec<LegacyAccount> {
    let mut out: Vec<LegacyAccount> = Vec::new();
    let mut current: Option<LegacyAccount> = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with(';') || line.starts_with('#') {
            continue;
        }
        if let Some(section) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            out.extend(current.take().filter(|a| !a.username.is_empty()));
            if section.starts_with("credentials") {
                current = Some(LegacyAccount {
                    section: section.to_string(),
                    ..Default::default()
                });
            }
            continue;
        }
        let Some(acc) = current.as_mut() else {
            continue;
        };
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let v = v.trim();
        match k.trim() {
            "name" => acc.name = v.to_string(),
            "username" => acc.username = v.to_string(),
            "login_method" => acc.login = login_method(v),
            "test_account" => acc.test_env = v == "true",
            "sync_with_all" => acc.sync_with_all = v == "true",
            "password" => acc.password = b64(v),
            "mep_token" => acc.mep_token = b64(v),
            "database_dir" => acc.db_dir = Some(ini_string(v)).filter(|d| !d.is_empty()),
            "p12file" => {
                acc.p12_file = Some(v.trim_matches('"').to_string()).filter(|p| !p.is_empty())
            }
            "password_alg" | "password_salt" | "password_iv" | "password_code" => {
                let v = v.trim_matches('"').to_string();
                match k.trim() {
                    "password_alg" => acc.pwd_alg = Some(v),
                    "password_salt" => acc.pwd_salt = Some(v),
                    "password_iv" => acc.pwd_iv = Some(v),
                    _ => acc.pwd_code = Some(v),
                }
                acc.pin_protected = acc.pwd_alg.is_some() || acc.pwd_code.is_some();
            }
            _ => {}
        }
    }
    out.extend(current.filter(|a| !a.username.is_empty()));
    out.sort_by_key(|a| {
        a.section
            .trim_start_matches("credentials")
            .parse::<u32>()
            .unwrap_or(1)
    });
    out
}

/// Accounts of `dsgui.conf`; a new, empty archive has none yet.
pub fn load(dir: &Path) -> Result<Vec<LegacyAccount>> {
    let path = dir.join("dsgui.conf");
    if !path.exists() {
        return Ok(Vec::new());
    }
    Ok(parse(&std::fs::read_to_string(path)?))
}

/// What the interface may see about an account. Secrets stay out: password,
/// mobile-key token, PIN material and the path of a certificate.
pub fn public_account(a: &LegacyAccount, info: &super::BoxInfo, pin_unlocked: bool) -> Value {
    json!({
        "username": a.username,
        "name": a.name,
        "login": a.login,
        "test_env": a.test_env,
        // Only what the chosen method uses counts: a mobile key code left
        // over from before does not make a password box able to log in.
        "has_credentials": match a.login {
            LoginMethod::MobileKey => a.mep_token.is_some(),
            _ => a.has_password() || (a.pin_protected && pin_unlocked),
        },
        "pin_protected": a.pin_protected,
        "box_id": info.box_id,
        "box_type": info.box_type,
        "owner": info.owner,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_database_folder_of_an_account() {
        let a = parse(
            "[credentials]\nusername=aaa\ndatabase_dir=/Volumes/Data/Datovka\n\
             [credentials2]\nusername=bbb\ndatabase_dir=\"C:/Data/Datovka, archiv\"\n\
             [credentials3]\nusername=ccc\ndatabase_dir=\n",
        );
        assert_eq!(a[0].db_dir.as_deref(), Some("/Volumes/Data/Datovka"));
        assert_eq!(a[1].db_dir.as_deref(), Some("C:/Data/Datovka, archiv"));
        assert_eq!(a[2].db_dir, None);
    }

    #[test]
    fn parses_accounts_in_order() {
        let conf = "[credentials2]\nname=Druhy\nusername=bbb\nlogin_method=mep\nmep_token=dG9r\n\
                    [credentials]\nname=Prvni\nusername=aaa\nlogin_method=username\npassword=aGVzbG8=\n\
                    test_account=false\n[version]\nconfig_format=1\n";
        let a = parse(conf);
        assert_eq!(a.len(), 2);
        assert_eq!(a[0].username, "aaa");
        assert_eq!(a[0].password.as_deref(), Some("heslo"));
        let shown = public_account(&a[0], &super::super::BoxInfo::default(), false).to_string();
        assert!(!shown.contains("heslo"), "heslo nesmí odejít do rozhraní");
        assert!(!shown.contains("aGVzbG8"), "ani jeho base64");
        let token = public_account(&a[1], &super::super::BoxInfo::default(), false).to_string();
        assert!(!token.contains("tok") && !token.contains("dG9r"));
        assert_eq!(a[1].login, LoginMethod::MobileKey);
        assert_eq!(a[1].mep_token.as_deref(), Some("tok"));
        assert_eq!(a[0].password_with_pin("1234").unwrap(), None);
        let has = |acc: &LegacyAccount| {
            public_account(acc, &super::super::BoxInfo::default(), false)["has_credentials"]
                .as_bool()
                .unwrap()
        };
        assert!(has(&a[0]) && has(&a[1]));
        // Switched from the mobile key to a password, nothing typed in yet.
        let switched = LegacyAccount {
            login: LoginMethod::Password,
            ..a[1].clone()
        };
        assert!(!has(&switched), "the old mobile key code is not a password");
    }

    #[test]
    fn decrypts_pin_protected_password() {
        let conf = "[credentials]\nname=A\nusername=aaa\nlogin_method=username\n\
                    password_alg=AES-256-CBC\npassword_salt=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\n\
                    password_iv=ZGVmZ2hpamtsbW5vcHFycw==\n\
                    password_code=Z75iqSyCrk9m2hZ+ZVSi230MZDrLYXTNVC/I3BY/3LU=\n";
        let a = &parse(conf)[0];
        assert!(a.pin_protected);
        assert!(!a.has_password());
        assert_eq!(
            a.password_with_pin("1234").unwrap().as_deref(),
            Some("Tajné heslo 123")
        );
        assert!(a.password_with_pin("0000").is_err());
    }
}

/// Sets (or adds) `key=value` in the account section of `username`, keeping
/// every other line of the file unchanged. Written atomically; the previous
/// file is kept as `dsgui.conf.bak`.
pub fn set_value(dir: &Path, username: &str, key: &str, value: &str) -> Result<()> {
    let path = dir.join("dsgui.conf");
    let text = std::fs::read_to_string(&path)?;
    let lines: Vec<&str> = text.lines().collect();

    // Find the section of the account.
    let mut section: Option<(usize, usize)> = None;
    let mut start = None;
    for (i, l) in lines.iter().enumerate() {
        if l.trim().starts_with('[') {
            if let (Some(s), None) = (start, section) {
                if account_section_has(&lines[s..i], username) {
                    section = Some((s, i));
                }
            }
            start = l.trim().starts_with("[credentials").then_some(i);
        }
    }
    if let (Some(s), None) = (start, section) {
        if account_section_has(&lines[s..], username) {
            section = Some((s, lines.len()));
        }
    }
    let (s, e) = section.ok_or_else(|| crate::Error::Isds {
        code: "account".into(),
        text: format!("účet {username} není v dsgui.conf"),
    })?;

    let entry = format!("{key}={value}");
    let mut out: Vec<String> = lines.iter().map(|l| l.to_string()).collect();
    match (s + 1..e).find(|&i| {
        lines[i]
            .split_once('=')
            .is_some_and(|(k, _)| k.trim() == key)
    }) {
        Some(i) => out[i] = entry,
        None => out.insert(e, entry),
    }
    let mut new_text = out.join("\n");
    if text.ends_with('\n') {
        new_text.push('\n');
    }
    std::fs::copy(&path, dir.join("dsgui.conf.bak"))?;
    let tmp = dir.join(".dsgui.conf.tmp");
    std::fs::write(&tmp, new_text)?;
    std::fs::rename(tmp, path)?;
    Ok(())
}

fn account_section_has(lines: &[&str], username: &str) -> bool {
    lines.iter().any(|l| {
        l.split_once('=')
            .is_some_and(|(k, v)| k.trim() == "username" && v.trim() == username)
    })
}

/// Stores a new password (base64, as the original app does).
pub fn set_password(dir: &Path, username: &str, password: &str) -> Result<()> {
    set_value(
        dir,
        username,
        "password",
        &base64::engine::general_purpose::STANDARD.encode(password),
    )
}

/// Switches the login method of an account. A non-empty [secret] is stored:
/// a password in the system password store, the mobile key communication
/// code in `dsgui.conf` like the original app does.
pub fn set_login(
    dir: &Path,
    username: &str,
    login: LoginMethod,
    secret: Option<&str>,
) -> Result<()> {
    let secret = secret.filter(|s| !s.is_empty());
    if secret.is_some() && login != LoginMethod::MobileKey {
        let pin = load(dir)?
            .into_iter()
            .any(|a| a.username == username && a.pin_protected);
        if pin {
            return Err(crate::Error::Isds {
                code: "account".into(),
                text: "uložené heslo je chráněné PINem, zadejte ho při přihlášení".into(),
            });
        }
    }
    set_value(dir, username, "login_method", login_method_name(login))?;
    if let Some(s) = secret {
        if login == LoginMethod::MobileKey {
            set_value(
                dir,
                username,
                "mep_token",
                &base64::engine::general_purpose::STANDARD.encode(s),
            )?;
            set_value(dir, username, "remember_password", "true")?;
        } else {
            let test_env = load(dir)?
                .into_iter()
                .any(|a| a.username == username && a.test_env);
            super::secrets::set_password(username, test_env, s)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod write_tests {
    use super::*;

    #[test]
    fn updates_only_the_account_section() {
        let dir = std::env::temp_dir().join(format!("datovka-conf-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let conf = "[credentials]\nname=A\nusername=aaa\npassword=b2xk\n\n[credentials2]\nname=B\nusername=bbb\n\n[version]\nconfig_format=1\n";
        std::fs::write(dir.join("dsgui.conf"), conf).unwrap();
        set_password(&dir, "bbb", "nove").unwrap();
        set_password(&dir, "aaa", "x").unwrap();
        let accs = load(&dir).unwrap();
        assert_eq!(accs[0].password.as_deref(), Some("x"));
        assert_eq!(accs[1].password.as_deref(), Some("nove"));
        let text = std::fs::read_to_string(dir.join("dsgui.conf")).unwrap();
        assert!(text.contains("[version]\nconfig_format=1\n"));
        set_value(&dir, "aaa", "name", "Nové jméno").unwrap();
        let renamed = load(&dir).unwrap();
        assert_eq!(renamed[0].name, "Nové jméno");
        assert_eq!(renamed[1].name, "B");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn switches_the_login_method() {
        let dir = std::env::temp_dir().join(format!("datovka-login-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let conf = "[credentials]\nname=A\nusername=aaa\nlogin_method=mep\nmep_token=dG9r\n\n\
                    [credentials2]\nname=B\nusername=bbb\nlogin_method=username\n\
                    password_alg=AES-256-CBC\npassword_code=xyz\n";
        std::fs::write(dir.join("dsgui.conf"), conf).unwrap();
        set_login(&dir, "aaa", LoginMethod::Password, Some("heslo")).unwrap();
        let a = &load(&dir).unwrap()[0];
        assert_eq!(a.login, LoginMethod::Password);
        assert_eq!(a.password, None, "the password is not in dsgui.conf");
        let text = std::fs::read_to_string(dir.join("dsgui.conf")).unwrap();
        assert!(!text.contains("heslo") && !text.contains("aGVzbG8"));
        assert_eq!(super::super::secrets::password("aaa", false).as_deref(), Some("heslo"));
        remove_account(&dir, "aaa").unwrap();
        assert_eq!(super::super::secrets::password("aaa", false), None);
        assert!(set_login(&dir, "bbb", LoginMethod::Password, Some("x")).is_err());
        set_login(&dir, "bbb", LoginMethod::PasswordTotp, None).unwrap();
        assert_eq!(load(&dir).unwrap()[0].login, LoginMethod::PasswordTotp);
        std::fs::remove_dir_all(dir).unwrap();
    }
}

/// Reorders account sections to follow `usernames` and renumbers them
/// (`[credentials]`, `[credentials2]`, …) like the original app. Other
/// sections and all values are kept; accounts not listed keep their order
/// after the listed ones. Written atomically with `dsgui.conf.bak`.
pub fn reorder(dir: &Path, usernames: &[String]) -> Result<()> {
    let path = dir.join("dsgui.conf");
    let text = std::fs::read_to_string(&path)?;

    // Split into a preamble and sections (header line + body lines).
    let mut preamble: Vec<&str> = Vec::new();
    let mut sections: Vec<(String, Vec<&str>)> = Vec::new();
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with('[') && t.ends_with(']') {
            sections.push((t[1..t.len() - 1].to_string(), Vec::new()));
        } else if let Some((_, body)) = sections.last_mut() {
            body.push(line);
        } else {
            preamble.push(line);
        }
    }
    let user_of = |body: &[&str]| {
        body.iter().find_map(|l| {
            l.split_once('=')
                .filter(|(k, _)| k.trim() == "username")
                .map(|(_, v)| v.trim().to_string())
        })
    };
    let (mut accounts, others): (Vec<_>, Vec<_>) = sections
        .into_iter()
        .partition(|(name, _)| name.starts_with("credentials"));
    accounts.sort_by_key(|(_, body)| {
        let u = user_of(body).unwrap_or_default();
        usernames.iter().position(|x| *x == u).unwrap_or(usize::MAX)
    });

    let mut out: Vec<String> = preamble.iter().map(|l| l.to_string()).collect();
    for (i, (_, body)) in accounts.iter().enumerate() {
        out.push(if i == 0 {
            "[credentials]".into()
        } else {
            format!("[credentials{}]", i + 1)
        });
        // Keep exactly one blank line between sections.
        let mut b: Vec<&str> = body.clone();
        while b.last().is_some_and(|l| l.trim().is_empty()) {
            b.pop();
        }
        out.extend(b.iter().map(|l| l.to_string()));
        out.push(String::new());
    }
    for (name, body) in &others {
        out.push(format!("[{name}]"));
        out.extend(body.iter().map(|l| l.to_string()));
    }
    let mut new_text = out.join("\n");
    if !new_text.ends_with('\n') {
        new_text.push('\n');
    }
    std::fs::copy(&path, dir.join("dsgui.conf.bak"))?;
    let tmp = dir.join(".dsgui.conf.tmp");
    std::fs::write(&tmp, new_text)?;
    std::fs::rename(tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod reorder_tests {
    use super::*;

    #[test]
    fn reorders_and_renumbers() {
        let dir = std::env::temp_dir().join(format!("datovka-order-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("dsgui.conf"),
            "[credentials]\nname=A\nusername=aaa\n\n[credentials2]\nname=B\nusername=bbb\n\n\
             [credentials3]\nname=C\nusername=ccc\n\n[version]\nconfig_format=1\n",
        )
        .unwrap();
        reorder(&dir, &["ccc".into(), "aaa".into(), "bbb".into()]).unwrap();
        let names: Vec<_> = load(&dir)
            .unwrap()
            .into_iter()
            .map(|a| a.username)
            .collect();
        assert_eq!(names, ["ccc", "aaa", "bbb"]);
        let text = std::fs::read_to_string(dir.join("dsgui.conf")).unwrap();
        assert!(text.starts_with("[credentials]\nname=C\n"));
        assert!(text.contains("[version]\nconfig_format=1\n"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}

/// `login_method` values of the original app.
fn login_method_name(m: LoginMethod) -> &'static str {
    match m {
        LoginMethod::Password => "username",
        LoginMethod::Certificate => "user_certificate",
        LoginMethod::PasswordHotp => "hotp",
        LoginMethod::PasswordTotp => "totp",
        LoginMethod::MobileKey => "mep",
    }
}

/// Appends an account section; `secret` is the password (or the mobile key
/// communication code), stored base64 like the original app does.
pub fn add_account(
    dir: &Path,
    name: &str,
    username: &str,
    login: LoginMethod,
    secret: Option<&str>,
    test_env: bool,
) -> Result<()> {
    let path = dir.join("dsgui.conf");
    let text = if path.exists() {
        std::fs::read_to_string(&path)?
    } else {
        "[version]\nconfig_format=1\n".to_string()
    };
    let existing = parse(&text);
    if existing.iter().any(|a| a.username == username) {
        return Err(crate::Error::Isds {
            code: "account".into(),
            text: format!("schránka {username} už je přidaná"),
        });
    }
    let b64 = |v: &str| base64::engine::general_purpose::STANDARD.encode(v);
    let mut section = format!(
        "[credentials{}]\nlogin_method={}\nname={}\n",
        existing.len() + 1,
        login_method_name(login),
        name.trim()
    );
    if let Some(s) = secret.filter(|s| !s.is_empty()) {
        if login == LoginMethod::MobileKey {
            section += &format!("mep_token={}\nremember_password=true\n", b64(s));
        } else {
            super::secrets::set_password(username, test_env, s)?;
        }
    }
    section += &format!("sync_with_all=true\ntest_account={test_env}\nusername={username}\n");
    // Insert before non-account sections (e.g. [version]).
    let at = text
        .match_indices("\n[")
        .map(|(i, _)| i + 1)
        .chain(text.starts_with('[').then_some(0))
        .filter(|&i| !text[i..].starts_with("[credentials"))
        .min()
        .unwrap_or(text.len());
    let mut new_text = text[..at].to_string();
    if !new_text.is_empty() && !new_text.ends_with("\n\n") {
        new_text.push('\n');
    }
    new_text += &section;
    new_text.push('\n');
    new_text += &text[at..];
    if path.exists() {
        std::fs::copy(&path, dir.join("dsgui.conf.bak"))?;
    }
    let tmp = dir.join(".dsgui.conf.tmp");
    std::fs::write(&tmp, new_text)?;
    std::fs::rename(tmp, &path)?;
    // Renumber sections in file order.
    let order: Vec<String> = parse(&std::fs::read_to_string(&path)?)
        .into_iter()
        .map(|a| a.username)
        .collect();
    reorder(dir, &order)
}

/// Removes an account section. Its message databases stay on disk.
pub fn remove_account(dir: &Path, username: &str) -> Result<()> {
    for a in load(dir)?.iter().filter(|a| a.username == username) {
        super::secrets::delete(username, a.test_env)?;
    }
    let order: Vec<String> = load(dir)?
        .into_iter()
        .map(|a| a.username)
        .filter(|u| u != username)
        .collect();
    let path = dir.join("dsgui.conf");
    let text = std::fs::read_to_string(&path)?;
    let mut out = Vec::new();
    let mut skip = false;
    let mut section: Vec<&str> = Vec::new();
    let flush = |section: &mut Vec<&str>, skip: bool, out: &mut Vec<String>| {
        if !skip {
            out.extend(section.iter().map(|l| l.to_string()));
        }
        section.clear();
    };
    for line in text.lines() {
        if line.trim().starts_with('[') {
            flush(&mut section, skip, &mut out);
            skip = false;
        }
        if line
            .split_once('=')
            .is_some_and(|(k, v)| k.trim() == "username" && v.trim() == username)
        {
            skip = true;
        }
        section.push(line);
    }
    flush(&mut section, skip, &mut out);
    std::fs::copy(&path, dir.join("dsgui.conf.bak"))?;
    let tmp = dir.join(".dsgui.conf.tmp");
    std::fs::write(&tmp, out.join("\n") + "\n")?;
    std::fs::rename(tmp, &path)?;
    reorder(dir, &order)
}

#[cfg(test)]
mod account_tests {
    use super::*;

    #[test]
    fn adds_and_removes_accounts() {
        let dir = std::env::temp_dir().join(format!("datovka-acc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("dsgui.conf"),
            "[credentials]\nname=A\nusername=aaa\n\n[version]\nconfig_format=1\n",
        )
        .unwrap();
        add_account(
            &dir,
            "Nová",
            "bbb",
            LoginMethod::Password,
            Some("tajne"),
            false,
        )
        .unwrap();
        add_account(
            &dir,
            "Klíč",
            "ccc",
            LoginMethod::MobileKey,
            Some("kod"),
            false,
        )
        .unwrap();
        assert!(add_account(&dir, "X", "bbb", LoginMethod::Password, None, false).is_err());
        let a = load(&dir).unwrap();
        assert_eq!(a.len(), 3);
        assert_eq!(a[1].password, None, "the password is not in dsgui.conf");
        assert_eq!(super::super::secrets::password("bbb", false).as_deref(), Some("tajne"));
        assert!(!std::fs::read_to_string(dir.join("dsgui.conf")).unwrap().contains("tajne"));
        assert_eq!(a[2].mep_token.as_deref(), Some("kod"));
        remove_account(&dir, "bbb").unwrap();
        assert_eq!(super::super::secrets::password("bbb", false), None);
        let names: Vec<_> = load(&dir)
            .unwrap()
            .into_iter()
            .map(|a| a.username)
            .collect();
        assert_eq!(names, ["aaa", "ccc"]);
        let text = std::fs::read_to_string(dir.join("dsgui.conf")).unwrap();
        assert!(text.contains("[credentials2]\n"));
        assert!(text.contains("[version]"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
