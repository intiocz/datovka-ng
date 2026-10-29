//! Records management service ("spisová služba") of the original Datovka.
//!
//! * REST client (`src/datovka_shared/records_management/io/records_management_connection.cpp`):
//!   `<url>/<service>` where `<url>` gets a trailing `/`, headers
//!   `Authentication: <token>`, `Accept` and `Content-Type: application/json`,
//!   GET when there is no request body (`service_info`, `upload_hierarchy`),
//!   POST otherwise (`upload_file`, `stored_files`). HTTP 200 (and 302) is a
//!   success, everything else an error. Timeout 900 s
//!   (`RECMGMT_COMMUNICATION_TIMEOUT_MS`).
//! * JSON formats (`src/datovka_shared/records_management/json/*.cpp`).
//! * Settings: `[records_management]` group of `dsgui.conf`
//!   (`src/datovka_shared/settings/records_management.cpp`): `location_url`,
//!   `access_token` (base64 of the UTF-8 token) or, when a PIN is set,
//!   `access_token_alg`, `access_token_salt`, `access_token_iv`,
//!   `access_token_code` (same cipher as passwords).
//! * Local cache `records_management.db` (`src/datovka_shared/io/records_management_db*.cpp`):
//!   tables `service_info` and `stored_files_messages`.

use std::path::Path;

use base64::Engine;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::error::{Error, Result};
use crate::legacy::pin;

/// `RECMGMT_COMMUNICATION_TIMEOUT_MS` = `ISDS_DOWNLOAD_TIMEOUT_MS` (`src/common.h`).
pub const TIMEOUT_SECS: u64 = 900;

/// Separator used in `stored_files_messages.joined_locations`.
pub const LIST_SEPARATOR: &str = "^";

fn err(text: impl Into<String>) -> Error {
    Error::Isds {
        code: "records".into(),
        text: text.into(),
    }
}

fn b64_encode(v: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(v)
}

fn b64_decode(v: &str) -> Result<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
        .decode(v.trim())
        .map_err(|e| err(format!("neplatné base64: {e}")))
}

// ---------------------------------------------------------------------------
// JSON formats
// ---------------------------------------------------------------------------

/// Error codes of `entry_error.cpp`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    NoError,
    MalformedRequest,
    MissingIdentifier,
    WrongIdentifier,
    UnsupportedFileFormat,
    AlreadyPresent,
    LimitExceeded,
    Unspecified,
}

impl ErrorCode {
    /// Explanation as in `ErrorEntry::trVerbose()`.
    pub fn explanation(self) -> &'static str {
        match self {
            Self::NoError => "Žádná chyba",
            Self::MalformedRequest => "Chybně formulovaný požadavek",
            Self::MissingIdentifier => "Chybí identifikátor",
            Self::WrongIdentifier => "Chybný identifikátor",
            Self::UnsupportedFileFormat => "Nepodporovaný formát souboru",
            Self::AlreadyPresent => "Data už jsou uložena",
            Self::LimitExceeded => "Překročen limit služby",
            Self::Unspecified => "Blíže neurčená chyba",
        }
    }
}

/// `{"code": "...", "description": "..."}` (both required).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorEntry {
    pub code: ErrorCode,
    pub description: String,
}

impl std::fmt::Display for ErrorEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let code = serde_json::to_value(self.code)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default();
        write!(f, "{code} ({})", self.code.explanation())?;
        if !self.description.is_empty() {
            write!(f, ": {}", self.description)?;
        }
        Ok(())
    }
}

/// Binary data carried as a base64 string.
fn ser_b64<S: Serializer>(v: &[u8], s: S) -> std::result::Result<S::Ok, S::Error> {
    s.serialize_str(&b64_encode(v))
}

fn de_b64<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Vec<u8>, D::Error> {
    let s = String::deserialize(d)?;
    base64::engine::general_purpose::STANDARD
        .decode(s.trim())
        .map_err(serde::de::Error::custom)
}

/// 64-bit integers carried as decimal strings (`Json::Int64StringList`).
fn ser_i64_str<S: Serializer>(v: &i64, s: S) -> std::result::Result<S::Ok, S::Error> {
    s.serialize_str(&v.to_string())
}

fn de_i64_str<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<i64, D::Error> {
    let s = String::deserialize(d)?;
    s.trim().parse().map_err(serde::de::Error::custom)
}

fn ser_i64_list<S: Serializer>(v: &[i64], s: S) -> std::result::Result<S::Ok, S::Error> {
    s.collect_seq(v.iter().map(|n| n.to_string()))
}

fn de_i64_list<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Vec<i64>, D::Error> {
    Vec::<String>::deserialize(d)?
        .iter()
        .map(|s| s.trim().parse().map_err(serde::de::Error::custom))
        .collect()
}

/// Response of `service_info` (`service_info.cpp`): all keys required,
/// `logo_svg` is base64 of an SVG image.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServiceInfo {
    #[serde(serialize_with = "ser_b64", deserialize_with = "de_b64")]
    pub logo_svg: Vec<u8>,
    pub name: String,
    pub token_name: String,
}

/// Node of the `upload_hierarchy` response (`upload_hierarchy.cpp`).
/// The root may have a null name; every node may have a null `id` (such
/// nodes cannot be upload targets). `case_id` and `court_case_id` are
/// optional and omitted when empty.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HierarchyNode {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub case_id: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub court_case_id: Vec<String>,
    pub id: Option<String>,
    pub metadata: Vec<String>,
    pub name: Option<String>,
    pub sub: Vec<HierarchyNode>,
}

impl HierarchyNode {
    /// Parses the response and checks that every sub-node has a name.
    pub fn from_json(data: &[u8]) -> Result<Self> {
        let root: Self = serde_json::from_slice(data)?;
        fn check(n: &HierarchyNode) -> Result<()> {
            for s in &n.sub {
                if s.name.is_none() {
                    return Err(err("uzel hierarchie bez názvu"));
                }
                check(s)?;
            }
            Ok(())
        }
        check(&root)?;
        Ok(root)
    }

    /// True when the node can be selected as an upload target.
    pub fn selectable(&self) -> bool {
        self.id.as_deref().is_some_and(|i| !i.is_empty())
    }
}

/// Request of `upload_file` (`upload_file.cpp`): location ids from the
/// hierarchy, file name and base64 file content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadFileReq {
    #[serde(serialize_with = "ser_b64", deserialize_with = "de_b64")]
    pub file_content: Vec<u8>,
    pub file_name: String,
    pub ids: Vec<String>,
}

/// Response of `upload_file`: `id` of the stored file, or an `error`, and
/// the `locations` where the file can now be found.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadFileResp {
    pub error: Option<ErrorEntry>,
    pub id: Option<String>,
    pub locations: Vec<String>,
}

impl UploadFileResp {
    /// `UploadFileResp::isValid()`.
    pub fn is_valid(&self) -> bool {
        (self.id.as_deref().is_some_and(|i| !i.is_empty()) && !self.locations.is_empty())
            || self
                .error
                .as_ref()
                .is_some_and(|e| e.code != ErrorCode::NoError)
    }
}

/// Request of `stored_files` (`stored_files.cpp`): message and delivery
/// info ids as decimal strings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredFilesReq {
    #[serde(serialize_with = "ser_i64_list", deserialize_with = "de_i64_list")]
    pub dm_ids: Vec<i64>,
    #[serde(serialize_with = "ser_i64_list", deserialize_with = "de_i64_list")]
    pub di_ids: Vec<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DmEntry {
    #[serde(serialize_with = "ser_i64_str", deserialize_with = "de_i64_str")]
    pub dm_id: i64,
    pub locations: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiEntry {
    #[serde(serialize_with = "ser_i64_str", deserialize_with = "de_i64_str")]
    pub di_id: i64,
    pub locations: Vec<String>,
}

/// Response of `stored_files`: entries with locations (empty = not stored),
/// the maximal number of ids per request and an optional error.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredFilesResp {
    pub dis: Vec<DiEntry>,
    pub dms: Vec<DmEntry>,
    pub error: Option<ErrorEntry>,
    pub limit: i32,
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Services of `records_management_connection.cpp`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Service {
    ServiceInfo,
    UploadHierarchy,
    UploadFile,
    StoredFiles,
}

impl Service {
    pub fn name(self) -> &'static str {
        match self {
            Self::ServiceInfo => "service_info",
            Self::UploadHierarchy => "upload_hierarchy",
            Self::UploadFile => "upload_file",
            Self::StoredFiles => "stored_files",
        }
    }
}

/// `constructUrl()`: base URL with a trailing slash plus the service name.
pub fn service_url(base: &str, service: Service) -> String {
    let mut u = base.trim().to_string();
    if !u.ends_with('/') {
        u.push('/');
    }
    u + service.name()
}

#[derive(Debug, Clone)]
pub struct Client {
    http: reqwest::Client,
    url: String,
    token: String,
}

impl Client {
    pub fn new(url: &str, token: &str) -> Result<Self> {
        if url.trim().is_empty() {
            return Err(err("není zadána adresa spisové služby"));
        }
        let http = crate::http_builder()
            .user_agent(concat!("Datovka/", env!("CARGO_PKG_VERSION")))
            .timeout(std::time::Duration::from_secs(TIMEOUT_SECS))
            // QNetworkAccessManager of the original does not follow
            // redirects; a 302 reply is accepted as it is.
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            http,
            url: url.trim().to_string(),
            token: token.trim().to_string(),
        })
    }

    /// `Connection::communicate()`: GET without body, POST with JSON body.
    pub async fn communicate(&self, service: Service, body: Option<Vec<u8>>) -> Result<Vec<u8>> {
        let url = service_url(&self.url, service);
        let req = match body {
            Some(b) if !b.is_empty() => self.http.post(&url).body(b),
            _ => self.http.get(&url),
        };
        let resp = req
            .header("Authentication", &self.token)
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .send()
            .await?;
        let status = resp.status().as_u16();
        let data = resp.bytes().await?.to_vec();
        if status != 200 && status != 302 {
            return Err(Error::HttpStatus {
                status,
                body: String::from_utf8_lossy(&data).chars().take(500).collect(),
            });
        }
        if data.is_empty() {
            return Err(err("spisová služba vrátila prázdnou odpověď"));
        }
        Ok(data)
    }

    pub async fn service_info(&self) -> Result<ServiceInfo> {
        let data = self.communicate(Service::ServiceInfo, None).await?;
        Ok(serde_json::from_slice(&data)?)
    }

    pub async fn upload_hierarchy(&self) -> Result<HierarchyNode> {
        let data = self.communicate(Service::UploadHierarchy, None).await?;
        HierarchyNode::from_json(&data)
    }

    /// Uploads one file into the given hierarchy locations.
    pub async fn upload_file(
        &self,
        ids: &[String],
        file_name: &str,
        content: &[u8],
    ) -> Result<UploadFileResp> {
        if ids.is_empty() || file_name.is_empty() || content.is_empty() {
            return Err(err("chybí cílové umístění, název nebo obsah souboru"));
        }
        let req = UploadFileReq {
            file_content: content.to_vec(),
            file_name: file_name.to_string(),
            ids: ids.to_vec(),
        };
        let data = self
            .communicate(Service::UploadFile, Some(serde_json::to_vec(&req)?))
            .await?;
        let resp: UploadFileResp = serde_json::from_slice(&data)?;
        if !resp.is_valid() {
            return Err(err("spisová služba vrátila neplatnou odpověď"));
        }
        Ok(resp)
    }

    /// One `stored_files` request.
    pub async fn stored_files(&self, dm_ids: &[i64], di_ids: &[i64]) -> Result<StoredFilesResp> {
        let req = StoredFilesReq {
            dm_ids: dm_ids.to_vec(),
            di_ids: di_ids.to_vec(),
        };
        let data = self
            .communicate(Service::StoredFiles, Some(serde_json::to_vec(&req)?))
            .await?;
        Ok(serde_json::from_slice(&data)?)
    }

    /// Queries all `dm_ids` in batches as `updateMessages()` of
    /// `task_records_management_stored_messages.cpp` does: the first request
    /// carries one id, the following ones as many as the returned `limit`.
    pub async fn stored_messages(&self, dm_ids: &[i64]) -> Result<Vec<DmEntry>> {
        let mut out = Vec::new();
        let mut pos = 0usize;
        let mut limit = 1usize;
        while pos < dm_ids.len() {
            let end = (pos + limit).min(dm_ids.len());
            let resp = self.stored_files(&dm_ids[pos..end], &[]).await?;
            if let Some(e) = resp.error.as_ref().filter(|e| e.code != ErrorCode::NoError) {
                return Err(err(format!("spisová služba: {e}")));
            }
            if resp.limit <= 0 {
                return Err(err("spisová služba vrátila neplatný limit"));
            }
            out.extend(resp.dms);
            pos = end;
            limit = resp.limit as usize;
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// Settings in dsgui.conf
// ---------------------------------------------------------------------------

const GROUP: &str = "records_management";
const KEY_URL: &str = "location_url";
const KEY_TOKEN: &str = "access_token";
const KEY_ALG: &str = "access_token_alg";
const KEY_SALT: &str = "access_token_salt";
const KEY_IV: &str = "access_token_iv";
const KEY_CODE: &str = "access_token_code";

/// Raw content of the `[records_management]` group.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StoredSettings {
    pub url: String,
    /// Plain token (decoded from base64 `access_token`).
    pub token: String,
    pub token_alg: String,
    pub token_salt: String,
    pub token_iv: String,
    pub token_code: String,
}

/// Strips the quotes `QSettings` puts around some INI values.
fn ini_value(v: &str) -> &str {
    let v = v.trim();
    v.strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .unwrap_or(v)
}

impl StoredSettings {
    /// `RecordsManagementSettings::loadFromSettings()`; invalid content
    /// (no URL or no token) yields empty settings.
    pub fn parse(conf_text: &str) -> Self {
        let mut s = Self::default();
        let mut inside = false;
        for line in conf_text.lines() {
            let line = line.trim();
            if let Some(g) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
                inside = g == GROUP;
                continue;
            }
            if !inside {
                continue;
            }
            let Some((k, v)) = line.split_once('=') else {
                continue;
            };
            let v = ini_value(v).to_string();
            match k.trim() {
                KEY_URL => s.url = v,
                KEY_TOKEN => {
                    s.token = b64_decode(&v)
                        .ok()
                        .and_then(|b| String::from_utf8(b).ok())
                        .unwrap_or_default()
                }
                KEY_ALG => s.token_alg = v,
                KEY_SALT => s.token_salt = v,
                KEY_IV => s.token_iv = v,
                KEY_CODE => s.token_code = v,
                _ => {}
            }
        }
        if !s.is_valid() {
            return Self::default();
        }
        s
    }

    /// `RecordsManagementSettings::isValid()`.
    pub fn is_valid(&self) -> bool {
        !self.url.is_empty()
            && (!self.token.is_empty()
                || (!self.token_alg.is_empty()
                    && !self.token_salt.is_empty()
                    && !self.token_iv.is_empty()
                    && !self.token_code.is_empty()))
    }

    pub fn encrypted(&self) -> bool {
        self.token.is_empty() && !self.token_code.is_empty()
    }

    /// The token, decrypted with `pin` when it is stored encrypted
    /// (`decryptToken()`). `None` when it is encrypted and no PIN is known.
    pub fn token(&self, pin: Option<&str>) -> Result<Option<String>> {
        if !self.token.is_empty() {
            return Ok(Some(self.token.clone()));
        }
        if self.token_code.is_empty() {
            return Ok(None);
        }
        match pin.filter(|p| !p.is_empty()) {
            None => Ok(None),
            Some(p) => pin::decrypt_password(
                &self.token_alg,
                &self.token_salt,
                &self.token_iv,
                &self.token_code,
                p,
            )
            .map(Some),
        }
    }

    /// Lines of the group as `saveToSettings()` writes them (keys sorted as
    /// `QSettings` does). Empty when URL or token is empty.
    pub fn lines(url: &str, token: &str, pin: Option<&str>) -> Result<Vec<String>> {
        let (url, token) = (url.trim(), token.trim());
        if url.is_empty() || token.is_empty() {
            return Ok(Vec::new());
        }
        let mut kv: Vec<(&str, String)> = vec![(KEY_URL, url.to_string())];
        match pin.filter(|p| !p.is_empty()) {
            Some(p) => {
                let (alg, salt, iv, code) = pin::encrypt_password(token, p)?;
                kv.extend([
                    (KEY_ALG, alg),
                    (KEY_SALT, salt),
                    (KEY_IV, iv),
                    (KEY_CODE, code),
                ]);
            }
            None => kv.push((KEY_TOKEN, b64_encode(token.as_bytes()))),
        }
        kv.sort_by(|a, b| a.0.cmp(b.0));
        Ok(kv.into_iter().map(|(k, v)| format!("{k}={v}")).collect())
    }
}

/// Replaces the `[group]` section of an INI text (or removes it when
/// `lines` is empty). A new section is appended at the end.
pub fn replace_section(text: &str, group: &str, lines: &[String]) -> String {
    let src: Vec<&str> = text.lines().collect();
    let header = format!("[{group}]");
    let start = src.iter().position(|l| l.trim() == header);
    let mut out: Vec<String> = Vec::new();
    let mut section = vec![header.clone()];
    section.extend(lines.iter().cloned());
    match start {
        Some(s) => {
            let e = src[s + 1..]
                .iter()
                .position(|l| l.trim().starts_with('['))
                .map_or(src.len(), |p| s + 1 + p);
            out.extend(src[..s].iter().map(|l| l.to_string()));
            if !lines.is_empty() {
                out.extend(section);
                out.push(String::new());
            }
            out.extend(src[e..].iter().map(|l| l.to_string()));
        }
        None => {
            out.extend(src.iter().map(|l| l.to_string()));
            if !lines.is_empty() {
                if out.last().is_some_and(|l| !l.trim().is_empty()) {
                    out.push(String::new());
                }
                out.extend(section);
            }
        }
    }
    while out.last().is_some_and(|l| l.trim().is_empty()) {
        out.pop();
    }
    let mut t = out.join("\n");
    if !t.is_empty() {
        t.push('\n');
    }
    t
}

/// Reads the settings from `dir/dsgui.conf` (empty when missing).
pub fn load_settings(dir: &Path) -> Result<StoredSettings> {
    match std::fs::read_to_string(dir.join("dsgui.conf")) {
        Ok(t) => Ok(StoredSettings::parse(&t)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(StoredSettings::default()),
        Err(e) => Err(e.into()),
    }
}

/// Writes the settings into `dir/dsgui.conf` (encrypted when `pin` is
/// given); an empty URL or token removes them. Atomic; the previous file is
/// kept as `dsgui.conf.bak`.
pub fn save_settings(dir: &Path, url: &str, token: &str, pin: Option<&str>) -> Result<()> {
    let path = dir.join("dsgui.conf");
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => {
            std::fs::copy(&path, dir.join("dsgui.conf.bak"))?;
            t
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e.into()),
    };
    let new_text = replace_section(&text, GROUP, &StoredSettings::lines(url, token, pin)?);
    let tmp = dir.join(".dsgui.conf.tmp");
    std::fs::write(&tmp, new_text)?;
    std::fs::rename(tmp, path)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// records_management.db
// ---------------------------------------------------------------------------

pub const DB_FILE: &str = "records_management.db";

const DB_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS service_info (
        url TEXT NOT NULL,
        name TEXT,
        token_name TEXT,
        logo_svg TEXT,
        PRIMARY KEY (url)
);
CREATE TABLE IF NOT EXISTS stored_files_messages (
        dm_id INTEGER NOT NULL,
        separator TEXT NOT NULL,
        joined_locations TEXT NOT NULL,
        PRIMARY KEY (dm_id)
);";

fn open_db(dir: &Path) -> Result<rusqlite::Connection> {
    let c = rusqlite::Connection::open(dir.join(DB_FILE))?;
    c.execute_batch(DB_SCHEMA)?;
    Ok(c)
}

/// `updateServiceInfo()`: keeps one row describing the service.
pub fn db_set_service_info(dir: &Path, url: &str, info: &ServiceInfo) -> Result<()> {
    let c = open_db(dir)?;
    c.execute("DELETE FROM service_info", [])?;
    c.execute(
        "INSERT INTO service_info (url, name, token_name, logo_svg) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![url, info.name, info.token_name, b64_encode(&info.logo_svg)],
    )?;
    Ok(())
}

/// Removes cached data: everything (`deleteAllEntries()`) or only the
/// message locations (`deleteAllStoredMsg()`).
pub fn db_clear(dir: &Path, also_service_info: bool) -> Result<()> {
    if !dir.join(DB_FILE).exists() {
        return Ok(());
    }
    let c = open_db(dir)?;
    c.execute("DELETE FROM stored_files_messages", [])?;
    if also_service_info {
        c.execute("DELETE FROM service_info", [])?;
    }
    Ok(())
}

/// `updateStoredMsg()` for non-empty locations, `deleteStoredMsg()` else.
pub fn db_set_locations(dir: &Path, dm_id: i64, locations: &[String]) -> Result<()> {
    let c = open_db(dir)?;
    if locations.is_empty() {
        c.execute(
            "DELETE FROM stored_files_messages WHERE dm_id = ?1",
            [dm_id],
        )?;
    } else {
        c.execute(
            "INSERT OR REPLACE INTO stored_files_messages (dm_id, separator, joined_locations) \
             VALUES (?1, ?2, ?3)",
            rusqlite::params![dm_id, LIST_SEPARATOR, locations.join(LIST_SEPARATOR)],
        )?;
    }
    Ok(())
}

/// `storedMsgLocations()`.
pub fn db_locations(dir: &Path, dm_id: i64) -> Result<Vec<String>> {
    use rusqlite::OptionalExtension;
    if !dir.join(DB_FILE).exists() {
        return Ok(Vec::new());
    }
    let c = open_db(dir)?;
    let row: Option<(String, String)> = c
        .query_row(
            "SELECT separator, joined_locations FROM stored_files_messages WHERE dm_id = ?1",
            [dm_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    Ok(row
        .map(|(sep, j)| j.split(sep.as_str()).map(str::to_string).collect())
        .unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    const HIER: &str =
        include_str!("../testdata/records/records_management_upload_hierarchy_reply.json");
    const HIER_001: &str =
        include_str!("../testdata/records/records_management_upload_hierarchy_reply_001.json");
    const CONF_PLAIN: &str = include_str!("../testdata/records/config_pin_token_disabled.conf");
    const CONF_PIN: &str = include_str!("../testdata/records/config_pin_token_enabled.conf");
    /// `expectedToken` of `tests/test_crypto_pin_token.cpp`.
    const TOKEN: &str = "jfsah40akv,za[2=40ta;fa32-=gfakg/;as-iqtgfag\\ak-4itagmaga4ag4jgaI)_#@FJWLSAB)*#HRFAS>Ckjha3;faj-354ga6333agfa4";
    const URL: &str = "https://records-management.service.cz/api/";

    #[test]
    fn urls() {
        assert_eq!(
            service_url("https://a.cz/api", Service::ServiceInfo),
            "https://a.cz/api/service_info"
        );
        assert_eq!(
            service_url("https://a.cz/api/", Service::StoredFiles),
            "https://a.cz/api/stored_files"
        );
    }

    #[test]
    fn hierarchy_from_original_tests() {
        let root = HierarchyNode::from_json(HIER_001.as_bytes()).unwrap();
        assert_eq!(root.name, None);
        assert_eq!(root.id, None);
        assert_eq!(root.sub.len(), 2);
        let n = &root.sub[0];
        assert_eq!(n.name.as_deref(), Some("name_000"));
        assert!(!n.selectable());
        assert_eq!(n.sub[0].id.as_deref(), Some("id_000_001"));
        assert_eq!(
            n.sub[0].case_id,
            vec!["case_id_000_001", "case_id_000_001a"]
        );
        assert!(n.sub[0].selectable());

        let root = HierarchyNode::from_json(HIER.as_bytes()).unwrap();
        assert_eq!(root.sub[0].name.as_deref(), Some("Interní spisy"));
        assert_eq!(root.sub[0].sub[0].id.as_deref(), Some("1"));
        assert_eq!(root.sub[0].sub[0].court_case_id, vec![""]);

        // Round trip keeps the content; empty case_id/court_case_id are
        // omitted as in `toJsonValRecursive()`.
        let out = serde_json::to_vec(&root).unwrap();
        assert_eq!(HierarchyNode::from_json(&out).unwrap(), root);
        let again: Value = serde_json::from_slice(&out).unwrap();
        assert!(again["sub"][1]["sub"][2].get("court_case_id").is_none());
    }

    #[test]
    fn hierarchy_rejects_unnamed_sub_node() {
        let j = r#"{"id":null,"metadata":[],"name":null,"sub":[{"id":"1","metadata":[],"name":null,"sub":[]}]}"#;
        assert!(HierarchyNode::from_json(j.as_bytes()).is_err());
        // metadata and sub are required.
        assert!(HierarchyNode::from_json(br#"{"id":null,"name":null,"sub":[]}"#).is_err());
    }

    #[test]
    fn service_info_json() {
        let j = json!({"logo_svg": "ZGF0YQ==", "name": "name", "token_name": "token_name"});
        let si: ServiceInfo = serde_json::from_value(j.clone()).unwrap();
        assert_eq!(si.logo_svg, b"data");
        assert_eq!(si.name, "name");
        assert_eq!(serde_json::to_value(&si).unwrap(), j);
        assert!(
            serde_json::from_value::<ServiceInfo>(json!({"name": "n", "token_name": "t"})).is_err()
        );
    }

    #[test]
    fn upload_file_json() {
        let req = UploadFileReq {
            file_content: b"data".to_vec(),
            file_name: "DDZ_123.zfo".into(),
            ids: vec!["1".into(), "7".into()],
        };
        assert_eq!(
            String::from_utf8(serde_json::to_vec(&req).unwrap()).unwrap(),
            r#"{"file_content":"ZGF0YQ==","file_name":"DDZ_123.zfo","ids":["1","7"]}"#
        );
        let ok: UploadFileResp = serde_json::from_str(
            r#"{"id":"abc","error":null,"locations":["location1","location2"]}"#,
        )
        .unwrap();
        assert!(ok.is_valid());
        assert_eq!(ok.locations, vec!["location1", "location2"]);
        let bad: UploadFileResp = serde_json::from_str(
            r#"{"id":null,"error":{"code":"ALREADY_PRESENT","description":"description"},"locations":[]}"#,
        )
        .unwrap();
        assert!(bad.is_valid());
        let e = bad.error.unwrap();
        assert_eq!(e.code, ErrorCode::AlreadyPresent);
        assert!(e.to_string().starts_with("ALREADY_PRESENT ("));
        assert!(serde_json::from_str::<UploadFileResp>(
            r#"{"id":null,"error":{"code":"BOGUS","description":""},"locations":[]}"#
        )
        .is_err());
    }

    #[test]
    fn stored_files_json() {
        let req = StoredFilesReq {
            dm_ids: vec![0, 1],
            di_ids: vec![2, 3],
        };
        let v = serde_json::to_value(&req).unwrap();
        assert_eq!(v, json!({"dm_ids": ["0", "1"], "di_ids": ["2", "3"]}));
        assert_eq!(serde_json::from_value::<StoredFilesReq>(v).unwrap(), req);

        let resp: StoredFilesResp = serde_json::from_value(json!({
            "dms": [{"dm_id": "12088458", "locations": ["location1", "location2"]},
                    {"dm_id": "3401761", "locations": []}],
            "dis": [],
            "limit": 100,
            "error": null
        }))
        .unwrap();
        assert_eq!(resp.dms[0].dm_id, 12088458);
        assert_eq!(resp.dms[1].locations.len(), 0);
        assert_eq!(resp.limit, 100);
        let back = serde_json::to_value(&resp).unwrap();
        assert_eq!(back["dms"][0]["dm_id"], json!("12088458"));
        assert!(serde_json::from_value::<StoredFilesResp>(json!({
            "dms": [{"dm_id": "x", "locations": []}], "dis": [], "limit": 1, "error": null
        }))
        .is_err());
    }

    #[test]
    fn settings_plain_from_original_tests() {
        let s = StoredSettings::parse(CONF_PLAIN);
        assert!(s.is_valid());
        assert!(!s.encrypted());
        assert_eq!(s.url, URL);
        assert_eq!(s.token(None).unwrap().as_deref(), Some(TOKEN));
    }

    #[test]
    fn settings_pin_from_original_tests() {
        let s = StoredSettings::parse(CONF_PIN);
        assert!(s.is_valid());
        assert!(s.encrypted());
        assert_eq!(s.url, URL);
        assert_eq!(s.token(None).unwrap(), None);
        assert_eq!(s.token(Some("1234")).unwrap().as_deref(), Some(TOKEN));
        assert!(s.token(Some("123")).is_err());
    }

    #[test]
    fn settings_write_matches_original_layout() {
        let lines = StoredSettings::lines(URL, TOKEN, None).unwrap();
        let expected: Vec<String> = CONF_PLAIN
            .lines()
            .skip(1)
            .filter(|l| !l.is_empty())
            .map(str::to_string)
            .collect();
        assert_eq!(lines, expected);

        let enc = StoredSettings::lines(URL, TOKEN, Some("1234")).unwrap();
        let text = format!("[records_management]\n{}\n", enc.join("\n"));
        let s = StoredSettings::parse(&text);
        assert!(s.encrypted());
        assert_eq!(s.token(Some("1234")).unwrap().as_deref(), Some(TOKEN));
    }

    #[test]
    fn section_replacement() {
        let text = "[credentials]\nname=A\n\n[records_management]\nlocation_url=x\naccess_token=eA==\n\n[security]\npin_alg=a\n";
        let lines = vec![
            "access_token=eQ==".to_string(),
            "location_url=y".to_string(),
        ];
        let t = replace_section(text, GROUP, &lines);
        assert_eq!(
            t,
            "[credentials]\nname=A\n\n[records_management]\naccess_token=eQ==\nlocation_url=y\n\n[security]\npin_alg=a\n"
        );
        let removed = replace_section(text, GROUP, &[]);
        assert_eq!(removed, "[credentials]\nname=A\n\n[security]\npin_alg=a\n");
        let added = replace_section("[credentials]\nname=A\n", GROUP, &lines);
        assert_eq!(
            added,
            "[credentials]\nname=A\n\n[records_management]\naccess_token=eQ==\nlocation_url=y\n"
        );
    }

    #[test]
    fn settings_file_and_db_roundtrip() {
        let dir = std::env::temp_dir().join(format!("dk_rm_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("dsgui.conf"),
            "[credentials]\nname=A\nusername=aaa\n",
        )
        .unwrap();
        save_settings(&dir, URL, TOKEN, None).unwrap();
        let s = load_settings(&dir).unwrap();
        assert_eq!(s.url, URL);
        assert_eq!(s.token(None).unwrap().as_deref(), Some(TOKEN));
        let accounts = crate::legacy::conf::load(&dir).unwrap();
        assert_eq!(accounts.len(), 1);
        save_settings(&dir, "", "", None).unwrap();
        assert!(!load_settings(&dir).unwrap().is_valid());

        db_set_locations(&dir, 42, &["a/b".into(), "c".into()]).unwrap();
        assert_eq!(db_locations(&dir, 42).unwrap(), vec!["a/b", "c"]);
        db_set_locations(&dir, 42, &[]).unwrap();
        assert!(db_locations(&dir, 42).unwrap().is_empty());
        let info = ServiceInfo {
            logo_svg: b"<svg/>".to_vec(),
            name: "n".into(),
            token_name: "t".into(),
        };
        db_set_service_info(&dir, URL, &info).unwrap();
        db_clear(&dir, true).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Minimal local HTTP server (no real service is contacted): answers
    /// each request with the canned body for its path and reports the
    /// request line, `Authentication` header and body.
    fn mock_server(
        replies: Vec<(&'static str, String)>,
    ) -> (String, std::sync::mpsc::Receiver<(String, String, String)>) {
        use std::io::{BufRead, BufReader, Read, Write};
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = format!("http://{}/api", l.local_addr().unwrap());
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut replies = replies.into_iter();
            for stream in l.incoming() {
                let Some((_, reply)) = replies.next() else {
                    break;
                };
                let mut stream = stream.unwrap();
                let mut r = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                r.read_line(&mut line).unwrap();
                let (mut auth, mut len) = (String::new(), 0usize);
                loop {
                    let mut h = String::new();
                    r.read_line(&mut h).unwrap();
                    let h = h.trim_end();
                    if h.is_empty() {
                        break;
                    }
                    let (k, v) = h.split_once(':').unwrap();
                    match k.to_ascii_lowercase().as_str() {
                        "authentication" => auth = v.trim().to_string(),
                        "content-length" => len = v.trim().parse().unwrap(),
                        _ => {}
                    }
                }
                let mut body = vec![0u8; len];
                r.read_exact(&mut body).unwrap();
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    reply.len(),
                    reply
                )
                .unwrap();
                tx.send((
                    line.trim().to_string(),
                    auth,
                    String::from_utf8(body).unwrap(),
                ))
                .unwrap();
            }
        });
        (addr, rx)
    }

    #[tokio::test]
    async fn client_against_local_mock() {
        let (url, rx) = mock_server(vec![
            (
                "service_info",
                r#"{"logo_svg":"PHN2Zy8+","name":"Spisovka","token_name":"Uživatel"}"#.into(),
            ),
            ("upload_hierarchy", HIER_001.into()),
            (
                "upload_file",
                r#"{"id":"f1","error":null,"locations":["A/B"]}"#.into(),
            ),
            (
                "stored_files",
                r#"{"dms":[{"dm_id":"5","locations":["A/B"]}],"dis":[],"limit":10,"error":null}"#
                    .into(),
            ),
            (
                "stored_files",
                r#"{"dms":[{"dm_id":"6","locations":[]},{"dm_id":"7","locations":[]}],"dis":[],"limit":10,"error":null}"#
                    .into(),
            ),
        ]);
        let c = Client::new(&url, "secret").unwrap();

        let si = c.service_info().await.unwrap();
        assert_eq!(si.logo_svg, b"<svg/>");
        assert_eq!(si.token_name, "Uživatel");
        let (line, auth, body) = rx.recv().unwrap();
        assert!(line.starts_with("GET /api/service_info "), "{line}");
        assert_eq!(auth, "secret");
        assert!(body.is_empty());

        let root = c.upload_hierarchy().await.unwrap();
        assert_eq!(root.sub.len(), 2);
        assert!(rx
            .recv()
            .unwrap()
            .0
            .starts_with("GET /api/upload_hierarchy "));

        let r = c
            .upload_file(&["id_000_001".into()], "DDZ_5.zfo", b"zfo")
            .await
            .unwrap();
        assert_eq!(r.locations, vec!["A/B"]);
        let (line, _, body) = rx.recv().unwrap();
        assert!(line.starts_with("POST /api/upload_file "), "{line}");
        assert_eq!(
            body,
            r#"{"file_content":"emZv","file_name":"DDZ_5.zfo","ids":["id_000_001"]}"#
        );

        let st = c.stored_messages(&[5, 6, 7]).await.unwrap();
        assert_eq!(st.len(), 3);
        let (line, _, body) = rx.recv().unwrap();
        assert!(line.starts_with("POST /api/stored_files "), "{line}");
        assert_eq!(body, r#"{"dm_ids":["5"],"di_ids":[]}"#);
        assert_eq!(rx.recv().unwrap().2, r#"{"dm_ids":["6","7"],"di_ids":[]}"#);
    }
}
