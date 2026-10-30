//! ISDS SOAP client (web service API of Czech data boxes).

mod multipart;
pub mod ops;
pub mod rules;
pub mod vodz;
#[cfg(test)]
mod schema_check;

use base64::Engine;
use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use crate::envelope;
use crate::error::{Error, Result};
use crate::model::{Envelope, OwnerInfo};
use crate::xml::{self, escape, Element};

const NS: &str = "http://isds.czechpoint.cz/v20";
const PROD_BASE: &str = "https://ws1.datovka.gov.cz/";
const TEST_BASE: &str = "https://ws1.datovka-test.gov.cz/";
/// Base of high-volume message (VoDZ) services for password logins.
const PROD_VODZ_BASE: &str = "https://ws2.datovka.gov.cz/";
const TEST_VODZ_BASE: &str = "https://ws2.datovka-test.gov.cz/";
/// Entry point for one-time password and mobile key logins.
const PROD_WWW: &str = "https://www.datovka.gov.cz/";
const TEST_WWW: &str = "https://www.datovka-test.gov.cz/";
/// Name shown in the Mobilní klíč app when it asks to confirm the login.
const APP_NAME: &str = "DATOVKA";

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LoginMethod {
    #[default]
    Password,
    /// Password + code sent by SMS. Not implemented yet.
    PasswordTotp,
    /// Password + HOTP token. Not implemented yet.
    PasswordHotp,
    /// "Mobilní klíč" app. Not implemented yet.
    MobileKey,
    /// Commercial certificate (+ optional password). Not implemented yet.
    Certificate,
}

#[derive(Debug, Clone)]
pub struct Credentials {
    pub username: String,
    pub password: String,
    pub method: LoginMethod,
    pub test_env: bool,
}

#[derive(Debug, Clone, Copy)]
pub enum Service {
    /// Message operations (download, send, authenticate): `DS/dz`.
    Dz,
    /// Message info (lists, delivery info, marking as read): `DS/dx`.
    Dx,
    DsManage,
    /// Data box directory search.
    Df,
}

impl Service {
    fn path(self) -> &'static str {
        match self {
            Service::Dz => "DS/dz",
            Service::Dx => "DS/dx",
            Service::DsManage => "DS/DsManage",
            Service::Df => "DS/df",
        }
    }
}

/// What a directory search matches against.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SearchType {
    /// Name, address and other fields.
    #[default]
    General,
    Address,
    Ico,
    BoxId,
    /// Identifier of a public authority (IdOVM, usually its IČO).
    IdOvm,
}

impl SearchType {
    fn as_str(self) -> &'static str {
        match self {
            SearchType::General => "GENERAL",
            SearchType::Address => "ADDRESS",
            SearchType::Ico => "ICO",
            SearchType::BoxId => "DBID",
            SearchType::IdOvm => "IDOVM",
        }
    }
}

/// A data box found in the ISDS directory.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct DirectoryEntry {
    pub box_id: String,
    pub box_type: Option<String>,
    pub name: Option<String>,
    pub address: Option<String>,
    pub ico: Option<String>,
    /// Identifier of a public authority (IdOVM).
    #[serde(default)]
    pub id_ovm: Option<String>,
    /// Box of a public authority (orgán veřejné moci).
    pub is_authority: bool,
    /// Which kinds of messages the box accepts, e.g. `ALL`, `PDZ`, `NONE`.
    pub send_options: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SearchPage {
    pub total: u32,
    pub last_page: bool,
    pub entries: Vec<DirectoryEntry>,
}

/// A file to send. The first file of a message is its main document.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutgoingFile {
    pub name: String,
    pub mime_type: String,
    #[serde(skip)]
    pub content: Vec<u8>,
}

/// A new message to send (`CreateMessage`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OutgoingMessage {
    pub recipient_box_id: String,
    pub annotation: String,
    #[serde(default)]
    pub to_hands: Option<String>,
    #[serde(default)]
    pub sender_ref_number: Option<String>,
    #[serde(default)]
    pub sender_ident: Option<String>,
    #[serde(default)]
    pub recipient_ref_number: Option<String>,
    #[serde(default)]
    pub recipient_ident: Option<String>,
    #[serde(default)]
    pub personal_delivery: bool,
    /// Allow delivery by fiction (substitute delivery); ISDS default is true.
    #[serde(default = "yes")]
    pub allow_subst_delivery: bool,
    /// Legal title (zmocnění): law number, year, section, paragraph, letter.
    #[serde(default)]
    pub legal_title_law: Option<String>,
    #[serde(default)]
    pub legal_title_year: Option<String>,
    #[serde(default)]
    pub legal_title_sect: Option<String>,
    #[serde(default)]
    pub legal_title_par: Option<String>,
    #[serde(default)]
    pub legal_title_point: Option<String>,
    /// Send as a public authority; `None` lets ISDS decide by the box type.
    #[serde(default)]
    pub ovm: Option<bool>,
    /// Show the sender's identity (name, address) to the recipient.
    #[serde(default)]
    pub publish_own_id: Option<bool>,
    /// Commercial message type: `I` initiating (recipient replies on the
    /// sender's account), `O` reply to an initiating message, `K` contract.
    #[serde(default)]
    pub dm_type: Option<String>,
    #[serde(skip)]
    pub files: Vec<OutgoingFile>,
}

fn yes() -> bool {
    true
}

/// The MIME type to send for a file name, from the list of formats ISDS
/// accepts ([`rules::mime_for`]).
pub fn mime_for(name: &str) -> &'static str {
    rules::mime_for(name)
}

fn opt_el(name: &str, v: &Option<String>) -> String {
    match v.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
        Some(v) => format!("<isds:{name}>{}</isds:{name}>", escape(v)),
        None => String::new(),
    }
}

/// Request body of `CreateMessage`; element order follows the ISDS schema.
pub(crate) fn create_message_body(m: &OutgoingMessage) -> String {
    format!("{}{}", envelope_element(m), files_element(m))
}

/// Most recipients of one `CreateMultipleMessage` call.
pub const MULTIPLE_MAX: usize = 50;

/// Request body of `CreateMultipleMessage`: the recipients (each with the
/// message's `K rukám`), then the envelope without recipient and the files.
pub(crate) fn create_multiple_body(m: &OutgoingMessage, recipients: &[String]) -> String {
    let to_hands = el_or_nil("dmToHands", &m.to_hands);
    let mut list = String::new();
    for r in recipients {
        list += &format!(
            "<isds:dmRecipient><isds:dbIDRecipient>{}</isds:dbIDRecipient>{to_hands}</isds:dmRecipient>",
            escape(r.trim())
        );
    }
    format!(
        "<isds:dmRecipients>{list}</isds:dmRecipients>{}{}",
        envelope_xml(m, false),
        files_element(m)
    )
}

/// Result per recipient of `CreateMultipleMessageResponse`, in request order.
fn parse_multiple(body: &Element, count: usize) -> Result<Vec<Result<String>>> {
    let list: Vec<_> = body
        .child("dmMultipleStatus")
        .map(|m| m.children_named("dmSingleStatus").collect())
        .unwrap_or_default();
    if list.len() != count {
        return Err(Error::Xml(format!(
            "ISDS vrátil {} výsledků pro {count} adresátů",
            list.len()
        )));
    }
    Ok(list
        .into_iter()
        .map(|s| {
            check_status(s)?;
            s.child_text("dmID")
                .ok_or_else(|| Error::Xml("odpověď bez dmID".into()))
        })
        .collect())
}

fn files_element(m: &OutgoingMessage) -> String {
    let mut files = String::new();
    for (i, f) in m.files.iter().enumerate() {
        files += &format!(
            concat!(
                r#"<isds:dmFile dmMimeType="{mime}" dmFileMetaType="{meta}" dmFileDescr="{name}">"#,
                "<isds:dmEncodedContent>{content}</isds:dmEncodedContent></isds:dmFile>"
            ),
            mime = escape(&f.mime_type),
            meta = if i == 0 { "main" } else { "enclosure" },
            name = escape(&f.name),
            content = base64::engine::general_purpose::STANDARD.encode(&f.content),
        );
    }
    format!("<isds:dmFiles>{files}</isds:dmFiles>")
}

/// The `dmEnvelope` element shared by `CreateMessage` and `CreateBigMessage`.
fn envelope_element(m: &OutgoingMessage) -> String {
    envelope_xml(m, true)
}

/// `<isds:name>v</isds:name>`, or `xsi:nil` when there is no value.
fn el_or_nil(name: &str, v: &Option<String>) -> String {
    match opt_el(name, v) {
        e if e.is_empty() => format!(r#"<isds:{name} xsi:nil="true"/>"#),
        e => e,
    }
}

/// `dmEnvelope`; without the recipient for `CreateMultipleMessage`, whose
/// recipients (and their `K rukám`) are listed in `dmRecipients`.
fn envelope_xml(m: &OutgoingMessage, with_recipient: bool) -> String {
    let mut env = String::new();
    if with_recipient {
        env += &format!(
            "<isds:dbIDRecipient>{}</isds:dbIDRecipient>",
            escape(m.recipient_box_id.trim())
        );
        env += &opt_el("dmToHands", &m.to_hands);
    }
    env += &format!(
        "<isds:dmAnnotation>{}</isds:dmAnnotation>",
        escape(m.annotation.trim())
    );
    env += &opt_el("dmRecipientRefNumber", &m.recipient_ref_number);
    env += &opt_el("dmSenderRefNumber", &m.sender_ref_number);
    env += &opt_el("dmRecipientIdent", &m.recipient_ident);
    env += &opt_el("dmSenderIdent", &m.sender_ident);
    env += &opt_el("dmLegalTitleLaw", &m.legal_title_law);
    env += &opt_el("dmLegalTitleYear", &m.legal_title_year);
    env += &opt_el("dmLegalTitleSect", &m.legal_title_sect);
    env += &opt_el("dmLegalTitlePar", &m.legal_title_par);
    env += &opt_el("dmLegalTitlePoint", &m.legal_title_point);
    env += &format!(
        "<isds:dmPersonalDelivery>{}</isds:dmPersonalDelivery>",
        m.personal_delivery
    );
    env += &format!(
        "<isds:dmAllowSubstDelivery>{}</isds:dmAllowSubstDelivery>",
        m.allow_subst_delivery
    );
    if let Some(v) = m.ovm {
        env += &format!("<isds:dmOVM>{v}</isds:dmOVM>");
    }
    if let Some(v) = m.publish_own_id {
        env += &format!("<isds:dmPublishOwnID>{v}</isds:dmPublishOwnID>");
    }

    let dm_type = match m.dm_type.as_deref().map(str::trim) {
        Some(t) if !t.is_empty() => format!(r#" dmType="{}""#, escape(t)),
        _ => String::new(),
    };
    format!("<isds:dmEnvelope{dm_type}>{env}</isds:dmEnvelope>")
}

/// Which messages to list.
#[derive(Debug, Clone, Default)]
pub struct ListFilter {
    pub from: Option<DateTime<Utc>>,
    pub to: Option<DateTime<Utc>>,
    pub offset: u32,
    pub limit: u32,
}

#[derive(Clone)]
pub struct Client {
    http: reqwest::Client,
    /// Prefix of service URLs, e.g. `https://ws1.datovka.gov.cz/` or, after an
    /// interactive login, `https://www.datovka.gov.cz/apps/`.
    base: String,
    /// Prefix of high-volume message (VoDZ) service URLs: `https://ws2.datovka.gov.cz/`,
    /// or the same `…/apps/` prefix as `base` after an interactive login.
    vodz_base: String,
    /// HTTP Basic credentials; `None` for cookie sessions.
    basic: Option<(String, String)>,
}

/// Progress of an interactive login.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LoginStep {
    /// Logged in, the client can be used.
    Done,
    /// An SMS code has been sent; call again with the code.
    SmsSent,
    /// Waiting for confirmation in the Mobilní klíč app.
    Waiting,
}

/// Mobile key login in progress (`as/processLogin?type=mep-ws`).
pub struct MobileKeyLogin {
    http: reqwest::Client,
    www: &'static str,
    username: String,
    code: String,
    login_url: String,
    intermediate: Option<String>,
}

/// ISDS checks attachments for viruses for up to about 240 seconds before it
/// answers (WSDL 3.09), so a request may take longer than that.
const REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(300);

fn http_client(cookies: bool) -> Result<reqwest::Client> {
    let mut b = crate::http_builder();
    if cookies {
        // ISDS closes idle connections of the login service quickly; reusing
        // them fails with "error sending request".
        b = b.pool_max_idle_per_host(0);
    }
    Ok(b.user_agent(concat!("Datovka/", env!("CARGO_PKG_VERSION")))
        .timeout(REQUEST_TIMEOUT)
        .cookie_store(cookies)
        .redirect(reqwest::redirect::Policy::none())
        .build()?)
}

/// Operations that only read or mark as read, so asking twice does no harm.
fn safe_to_repeat(op: &str) -> bool {
    ["Get", "DummyOperation", "MessageDownload", "MessageEnvelopeDownload", "Find", "ISDSSearch", "Check", "PDZInfo", "PDZSendInfo", "DataBoxCreditInfo", "MarkMessageAs", "PickUp", "Authenticate", "Verify", "SignedMessage", "SignedSent"]
        .iter()
        .any(|p| op.starts_with(p))
}

fn dummy_envelope() -> String {
    format!(
        concat!(
            r#"<?xml version="1.0" encoding="UTF-8"?>"#,
            r#"<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" "#,
            r#"xmlns:isds="{ns}"><soap:Body><isds:DummyOperation/></soap:Body></soap:Envelope>"#
        ),
        ns = NS
    )
}

fn header(resp: &reqwest::Response, name: &str) -> Option<String> {
    resp.headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
}

/// Error for a refused interactive login, using ISDS's own explanation.
fn login_refused(resp: &reqwest::Response) -> Error {
    let status = resp.status().as_u16();
    Error::Isds {
        code: header(resp, "x-response-message-code").unwrap_or_else(|| format!("HTTP {status}")),
        text: header(resp, "x-response-message-text")
            .unwrap_or_else(|| format!("ISDS přihlášení odmítl (HTTP {status})")),
    }
}

impl Client {
    pub fn new(creds: Credentials) -> Result<Self> {
        if creds.method != LoginMethod::Password {
            return Err(Error::Isds {
                code: "unsupported".into(),
                text: format!(
                    "způsob přihlášení {:?} vyžaduje interaktivní přihlášení",
                    creds.method
                ),
            });
        }
        Ok(Self {
            http: http_client(false)?,
            base: (if creds.test_env { TEST_BASE } else { PROD_BASE }).to_string(),
            vodz_base: (if creds.test_env {
                TEST_VODZ_BASE
            } else {
                PROD_VODZ_BASE
            })
            .to_string(),
            basic: Some((creds.username, creds.password)),
        })
    }

    /// Login with a client certificate (PKCS#12). With a password it is a
    /// user certificate plus name and password (`certds/`), without one the
    /// system certificate of a box, which needs no name (`cert/`). `hspis/`
    /// is for hosted records services only (ISDS operating rules, 26. 6. 2026).
    #[cfg(not(target_os = "android"))]
    pub fn with_certificate(
        username: &str,
        password: Option<&str>,
        p12: &[u8],
        passphrase: &str,
        test_env: bool,
    ) -> Result<Self> {
        let identity =
            reqwest::Identity::from_pkcs12_der(p12, passphrase).map_err(|e| Error::Isds {
                code: "cert".into(),
                text: format!("certifikát nelze načíst (špatné heslo?): {e}"),
            })?;
        let http = crate::http_builder()
            .user_agent(concat!("Datovka/", env!("CARGO_PKG_VERSION")))
            .timeout(REQUEST_TIMEOUT)
            .use_native_tls()
            .identity(identity)
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        let host = if test_env {
            "https://ws1c.datovka-test.gov.cz/"
        } else {
            "https://ws1c.datovka.gov.cz/"
        };
        let prefix = if password.is_some() { "certds/" } else { "cert/" };
        Ok(Self {
            http,
            base: format!("{host}{prefix}"),
            basic: password.map(|p| (username.to_string(), p.to_string())),
            vodz_base: format!(
                "{}{prefix}",
                if test_env {
                    "https://ws2c.datovka-test.gov.cz/"
                } else {
                    "https://ws2c.datovka.gov.cz/"
                }
            ),
        })
    }

    fn session(http: reqwest::Client, www: &str) -> Self {
        Self {
            http,
            base: format!("{www}apps/"),
            vodz_base: format!("{www}apps/"),
            basic: None,
        }
    }

    /// Password + one-time code (HOTP from a token/app, or TOTP sent by SMS).
    ///
    /// For SMS call first with `code = None`: ISDS sends the SMS and the result
    /// is [`LoginStep::SmsSent`]; then call again with the code.
    pub async fn login_otp(
        username: &str,
        password: &str,
        code: Option<&str>,
        sms: bool,
        test_env: bool,
    ) -> Result<(LoginStep, Option<Client>)> {
        let www = if test_env { TEST_WWW } else { PROD_WWW };
        let http = http_client(true)?;
        let kind = if sms { "totp" } else { "hotp" };
        let url = match (sms, code) {
            (true, None) => {
                format!("{www}as/processLogin?type=totp&sendSms=true&uri={www}apps/DS/dz")
            }
            _ => format!("{www}as/processLogin?type={kind}&uri={www}apps/DS/dz"),
        };
        let secret = format!("{password}{}", code.unwrap_or(""));
        let resp = http
            .post(&url)
            .basic_auth(username, Some(secret))
            .header("Content-Type", "text/xml; charset=utf-8")
            .body(dummy_envelope())
            .send()
            .await?;
        let msg = header(&resp, "x-response-message-code").unwrap_or_default();
        if sms && code.is_none() {
            return if msg.contains("totpSended") || resp.status().is_redirection() {
                Ok((LoginStep::SmsSent, None))
            } else {
                Err(login_refused(&resp))
            };
        }
        if !resp.status().is_redirection() {
            return Err(login_refused(&resp));
        }
        // Finish the login at the redirect target; from now on the cookie authenticates.
        if let Some(next) = header(&resp, "location") {
            let fin = http
                .post(&next)
                .header("Content-Type", "text/xml; charset=utf-8")
                .body(dummy_envelope())
                .send()
                .await?;
            if fin.status() == reqwest::StatusCode::UNAUTHORIZED {
                return Err(login_refused(&fin));
            }
        }
        Ok((LoginStep::Done, Some(Client::session(http, www))))
    }

    /// Starts a mobile key login: ISDS sends a push to the user's phone.
    pub async fn login_mobile_key(
        username: &str,
        communication_code: &str,
        test_env: bool,
    ) -> Result<MobileKeyLogin> {
        let www = if test_env { TEST_WWW } else { PROD_WWW };
        let mut login = MobileKeyLogin {
            http: http_client(true)?,
            www,
            username: username.to_string(),
            code: communication_code.to_string(),
            login_url: format!(
                "{www}as/processLogin?type=mep-ws&applicationName={APP_NAME}&uri={www}apps/DS/dz"
            ),
            intermediate: None,
        };
        let resp = login.post_login().await?;
        match resp.status().as_u16() {
            302 | 303 => {
                login.intermediate = header(&resp, "location");
                if login.intermediate.is_none() {
                    return Err(Error::Xml("mobilní klíč: chybí adresa pro čekání".into()));
                }
                Ok(login)
            }
            400 => Err(Error::Isds {
                code: "mep".into(),
                text: "komunikační kód mobilního klíče nebyl rozpoznán".into(),
            }),
            _ => Err(login_refused(&resp)),
        }
    }
}

impl MobileKeyLogin {
    async fn post_login(&self) -> Result<reqwest::Response> {
        Ok(self
            .http
            .post(&self.login_url)
            .basic_auth(&self.username, Some(&self.code))
            .header("Content-Type", "text/xml; charset=utf-8")
            .body(dummy_envelope())
            .send()
            .await?)
    }

    /// Asks once whether the user confirmed the login in the app.
    pub async fn poll(&mut self) -> Result<LoginStep> {
        let url = self
            .intermediate
            .clone()
            .ok_or_else(|| Error::Xml("přihlášení mobilním klíčem už skončilo".into()))?;
        // Transient network errors while waiting are retried, not fatal.
        let mut attempt = 0;
        let body = loop {
            let r = self
                .http
                .get(&url)
                .basic_auth(&self.username, Some(&self.code))
                .send()
                .await;
            match r {
                Ok(resp) => break resp.text().await?,
                Err(_) if attempt < 2 => {
                    attempt += 1;
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
                Err(e) if e.is_connect() || e.is_request() || e.is_timeout() => {
                    return Ok(LoginStep::Waiting)
                }
                Err(e) => return Err(e.into()),
            }
        };
        match body.trim() {
            "1" => Ok(LoginStep::Waiting),
            "2" => {
                self.intermediate = None;
                let fin = self.post_login().await?;
                if fin.status().is_redirection() || fin.status().is_success() {
                    Ok(LoginStep::Done)
                } else {
                    Err(login_refused(&fin))
                }
            }
            "3" => Err(Error::Isds {
                code: "mep".into(),
                text: "přihlášení bylo v aplikaci odmítnuto nebo vypršelo".into(),
            }),
            "-1" => Err(Error::Isds {
                code: "mep".into(),
                text: "ISDS žádost o přihlášení nerozpoznal".into(),
            }),
            other => Err(Error::Xml(format!(
                "mobilní klíč: neočekávaná odpověď {other}"
            ))),
        }
    }

    /// Client for the logged-in session; call after `poll` returned `Done`.
    pub fn into_client(self) -> Client {
        Client::session(self.http, self.www)
    }
}

impl Client {
    /// Sends a SOAP request and returns the first element inside `Body`.
    async fn call(&self, service: Service, op: &str, inner: &str) -> Result<Response> {
        let url = format!("{}{}", self.base, service.path());
        self.call_at(&url, op, inner).await
    }

    /// Sends a SOAP 1.1 request to a full service URL.
    async fn call_at(&self, url: &str, op: &str, inner: &str) -> Result<Response> {
        self.call_ns(url, NS, op, inner).await
    }

    /// [`call_at`](Self::call_at) for a service with its own namespace.
    async fn call_ns(&self, url: &str, ns: &str, op: &str, inner: &str) -> Result<Response> {
        let body = format!(
            concat!(
                r#"<?xml version="1.0" encoding="UTF-8"?>"#,
                r#"<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" "#,
                r#"xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:isds="{ns}">"#,
                r#"<soap:Body><isds:{op}>{inner}</isds:{op}></soap:Body></soap:Envelope>"#
            ),
            ns = ns,
            op = op,
            inner = inner
        );
        let req = self
            .http
            .post(url)
            .header("Content-Type", "text/xml; charset=utf-8")
            .header("Accept", "application/soap+xml,application/xml,text/xml")
            .header("SOAPAction", "\"\"")
            .body(body);
        self.send_op(req, safe_to_repeat(op)).await
    }

    /// Adds authentication, sends a prepared SOAP request and returns the
    /// first element inside `Body` (SOAP 1.1 or 1.2, plain or MTOM/XOP).
    async fn send(&self, req: reqwest::RequestBuilder) -> Result<Response> {
        self.send_op(req, false).await
    }

    /// Like [`send`](Self::send). A connection that could not be opened is
    /// tried again: nothing reached ISDS yet, which happens when a phone
    /// wakes up before its network. A connection that broke on the way is
    /// tried again only for [`repeat`]able reads, never for sending.
    async fn send_op(&self, mut req: reqwest::RequestBuilder, repeat: bool) -> Result<Response> {
        if let Some((user, pass)) = &self.basic {
            req = req.basic_auth(user, Some(pass));
        }
        let mut tries = 0;
        let resp = loop {
            let again = req.try_clone();
            match req.send().await {
                Ok(r) => break r,
                Err(e)
                    if tries < 2
                        && again.is_some()
                        && (e.is_connect() || (repeat && e.is_request())) =>
                {
                    tries += 1;
                    tokio::time::sleep(std::time::Duration::from_millis(800 * tries)).await;
                    req = again.unwrap();
                }
                Err(e) => return Err(e.into()),
            }
        };

        let status = resp.status();
        // A cookie session that expired is redirected back to the login page.
        if status == reqwest::StatusCode::UNAUTHORIZED || status.is_redirection() {
            return Err(Error::Unauthorized);
        }
        let header = |n: &str| {
            resp.headers()
                .get(n)
                .and_then(|v| v.to_str().ok())
                .map(str::to_string)
        };
        let content_type = header("content-type").unwrap_or_default();
        let isds_code = header("x-response-message-code");
        let isds_text = header("x-response-message-text");
        let bytes = resp.bytes().await?;

        if !status.is_success() {
            if let Some(code) = isds_code {
                return Err(Error::Isds {
                    code,
                    text: isds_text.unwrap_or_default(),
                });
            }
            return Err(Error::HttpStatus {
                status: status.as_u16(),
                body: String::from_utf8_lossy(&bytes).chars().take(500).collect(),
            });
        }

        let (xml_bytes, parts) = if content_type.starts_with("multipart/") {
            multipart::split(&content_type, &bytes)?
        } else {
            (bytes.to_vec(), Vec::new())
        };
        let root = xml::parse(&xml_bytes)?;
        if let Some(fault) = root.find("Fault") {
            // SOAP 1.1: faultcode/faultstring; SOAP 1.2: Code/Value, Reason/Text.
            return Err(Error::Isds {
                code: fault
                    .child_text("faultcode")
                    .or_else(|| fault.find("Value").map(|v| v.text.trim().to_string()))
                    .unwrap_or_default(),
                text: fault
                    .child_text("faultstring")
                    .or_else(|| fault.find("Text").map(|t| t.text.trim().to_string()))
                    .unwrap_or_default(),
            });
        }
        let body = root
            .find("Body")
            .and_then(|b| b.children.first())
            .cloned()
            .ok_or_else(|| Error::Xml("odpověď bez SOAP Body".into()))?;
        check_status(&body)?;
        Ok(Response { body, parts })
    }

    pub async fn owner_info(&self) -> Result<OwnerInfo> {
        let r = self
            .call(
                Service::DsManage,
                "GetOwnerInfoFromLogin",
                "<isds:dbDummy/>",
            )
            .await?;
        let o = r
            .body
            .find("dbOwnerInfo")
            .ok_or_else(|| Error::Xml("chybí dbOwnerInfo".into()))?;
        let person = [o.child_text("pnFirstName"), o.child_text("pnLastName")]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" ");
        Ok(OwnerInfo {
            box_id: o.child_text("dbID").unwrap_or_default(),
            box_type: o.child_text("dbType"),
            name: o
                .child_text("firmName")
                .or_else(|| (!person.is_empty()).then_some(person)),
            ic: o.child_text("ic"),
        })
    }

    /// Date when the password expires, `None` when it does not expire.
    pub async fn password_expiry(&self) -> Result<Option<DateTime<Utc>>> {
        let r = self
            .call(Service::DsManage, "GetPasswordInfo", "<isds:dbDummy/>")
            .await?;
        Ok(r.body
            .child_text("pswExpDate")
            .and_then(|v| envelope::parse_time(&v)))
    }

    async fn list(&self, op: &str, unit: &str, f: &ListFilter) -> Result<Vec<Envelope>> {
        let time = |t: Option<DateTime<Utc>>, name: &str| match t {
            Some(t) => format!("<isds:{name}>{}</isds:{name}>", t.to_rfc3339()),
            None => format!(r#"<isds:{name} xsi:nil="true"/>"#),
        };
        let inner = format!(
            concat!(
                "{from}{to}",
                r#"<isds:{unit} xsi:nil="true"/>"#,
                "<isds:dmStatusFilter>-1</isds:dmStatusFilter>",
                "<isds:dmOffset>{offset}</isds:dmOffset>",
                "<isds:dmLimit>{limit}</isds:dmLimit>"
            ),
            from = time(f.from, "dmFromTime"),
            to = time(f.to, "dmToTime"),
            unit = unit,
            offset = f.offset.max(1),
            limit = if f.limit == 0 { 10_000 } else { f.limit },
        );
        let r = self.call(Service::Dx, op, &inner).await?;
        Ok(r.body
            .find("dmRecords")
            .map(|recs| {
                recs.children_named("dmRecord")
                    .map(|rec| envelope::from_elements(&[rec]))
                    .collect()
            })
            .unwrap_or_default())
    }

    pub async fn received_messages(&self, f: &ListFilter) -> Result<Vec<Envelope>> {
        self.list("GetListOfReceivedMessages", "dmRecipientOrgUnitNum", f)
            .await
    }

    pub async fn sent_messages(&self, f: &ListFilter) -> Result<Vec<Envelope>> {
        self.list("GetListOfSentMessages", "dmSenderOrgUnitNum", f)
            .await
    }

    async fn signed(&self, service: Service, op: &str, dm_id: &str) -> Result<Vec<u8>> {
        let inner = format!("<isds:dmID>{}</isds:dmID>", escape(dm_id));
        let r = self.call(service, op, &inner).await?;
        r.binary("dmSignature")
    }

    /// Downloads a received message as signed ZFO. Downloading marks it as delivered.
    pub async fn download_received(&self, dm_id: &str) -> Result<Vec<u8>> {
        self.signed(Service::Dz, "SignedMessageDownload", dm_id)
            .await
    }

    pub async fn download_sent(&self, dm_id: &str) -> Result<Vec<u8>> {
        self.signed(Service::Dz, "SignedSentMessageDownload", dm_id)
            .await
    }

    pub async fn download_delivery_info(&self, dm_id: &str) -> Result<Vec<u8>> {
        self.signed(Service::Dx, "GetSignedDeliveryInfo", dm_id)
            .await
    }

    /// Full-text search in the public data box directory (`ISDSSearch3`, the
    /// same search as the ISDS portal; it knows all current box types).
    pub async fn search_boxes(
        &self,
        text: &str,
        kind: SearchType,
        authorities_only: bool,
        page: u32,
    ) -> Result<SearchPage> {
        let inner = format!(
            concat!(
                "<isds:searchText>{text}</isds:searchText>",
                "<isds:searchType>{kind}</isds:searchType>",
                "<isds:searchScope>{scope}</isds:searchScope>",
                "<isds:page>{page}</isds:page>",
                "<isds:pageSize>50</isds:pageSize>",
                "<isds:highlighting>false</isds:highlighting>"
            ),
            text = escape(text),
            kind = kind.as_str(),
            scope = if authorities_only { "OVM" } else { "ALL" },
            page = page,
        );
        let r = self.call(Service::Df, "ISDSSearch3", &inner).await?;
        Ok(parse_search(&r.body))
    }

    /// Sends a message; returns the new message ID.
    pub async fn create_message(&self, m: &OutgoingMessage) -> Result<String> {
        if m.files.is_empty() {
            return Err(Error::Isds {
                code: "files".into(),
                text: "zpráva musí mít aspoň jednu přílohu".into(),
            });
        }
        if m.recipient_box_id.trim().is_empty() || m.annotation.trim().is_empty() {
            return Err(Error::Isds {
                code: "envelope".into(),
                text: "chybí adresát nebo věc zprávy".into(),
            });
        }
        let r = self
            .call(Service::Dz, "CreateMessage", &create_message_body(m))
            .await?;
        r.body
            .child_text("dmID")
            .ok_or_else(|| Error::Xml("odpověď bez dmID".into()))
    }

    /// Sends one message to several recipients in one call (at most
    /// [`MULTIPLE_MAX`]). Returns, per recipient in the given order, the new
    /// message ID or why ISDS did not create that message. An error of the
    /// whole call means that ISDS created no message.
    pub async fn create_multiple_message(
        &self,
        m: &OutgoingMessage,
        recipients: &[String],
    ) -> Result<Vec<Result<String>>> {
        if m.files.is_empty() {
            return Err(Error::Isds {
                code: "files".into(),
                text: "zpráva musí mít aspoň jednu přílohu".into(),
            });
        }
        if recipients.is_empty() || m.annotation.trim().is_empty() {
            return Err(Error::Isds {
                code: "envelope".into(),
                text: "chybí adresát nebo věc zprávy".into(),
            });
        }
        if recipients.len() > MULTIPLE_MAX {
            return Err(Error::Isds {
                code: "envelope".into(),
                text: format!("najednou lze poslat nejvýš {MULTIPLE_MAX} adresátům"),
            });
        }
        let r = self
            .call(
                Service::Dz,
                "CreateMultipleMessage",
                &create_multiple_body(m, recipients),
            )
            .await?;
        parse_multiple(&r.body, recipients.len())
    }

    pub async fn mark_as_read(&self, dm_id: &str) -> Result<()> {
        let inner = format!("<isds:dmID>{}</isds:dmID>", escape(dm_id));
        self.call(Service::Dx, "MarkMessageAsDownloaded", &inner)
            .await?;
        Ok(())
    }
}

struct Response {
    body: Element,
    /// MTOM/XOP binary parts as (Content-ID, data).
    parts: Vec<(String, Vec<u8>)>,
}

impl Response {
    /// Binary content of an element: either base64 text or an XOP reference.
    fn binary(&self, name: &str) -> Result<Vec<u8>> {
        let el = self
            .body
            .find(name)
            .ok_or_else(|| Error::Xml(format!("chybí {name}")))?;
        if let Some(href) = el.child("Include").and_then(|i| i.attr("href")) {
            let cid = href.trim_start_matches("cid:");
            let cid = percent_decode(cid);
            return self
                .parts
                .iter()
                .find(|(id, _)| *id == cid)
                .map(|(_, d)| d.clone())
                .ok_or_else(|| Error::Xml(format!("chybí MTOM část {cid}")));
        }
        let b64: String = el.text.split_whitespace().collect();
        base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| Error::Xml(format!("{name}: {e}")))
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn parse_search(body: &Element) -> SearchPage {
    let entries = body
        .find("dbResults")
        .map(|r| {
            r.children_named("dbResult")
                .map(|e| DirectoryEntry {
                    box_id: e.child_text("dbID").unwrap_or_default(),
                    box_type: e.child_text("dbType"),
                    name: e.child_text("dbName"),
                    address: e.child_text("dbAddress"),
                    ico: e.child_text("dbICO"),
                    id_ovm: e.child_text("dbIdOVM"),
                    // ISDSSearch3 has no dbEffectiveOVM; authorities are the OVM types.
                    is_authority: e.child_text("dbEffectiveOVM").as_deref() == Some("true")
                        || e.child_text("dbType").is_some_and(|t| t.trim().starts_with("OVM")),
                    send_options: e.child_text("dbSendOptions"),
                })
                .collect()
        })
        .unwrap_or_default();
    SearchPage {
        total: body
            .child_text("totalCount")
            .and_then(|v| v.parse().ok())
            .unwrap_or(0),
        // xs:boolean: ISDSSearch3 answers 0/1.
        last_page: !matches!(body.child_text("lastPage").as_deref(), Some("false" | "0")),
        entries,
    }
}

/// ISDS reports errors in `dmStatus`/`dbStatus`; code `0000` means success.
fn check_status(body: &Element) -> Result<()> {
    // The response's own status first: a multiple message also has one
    // status per recipient deeper inside.
    let status = body
        .child("dmStatus")
        .or_else(|| body.child("dbStatus"))
        .or_else(|| body.find("dmStatus"))
        .or_else(|| body.find("dbStatus"));
    let Some(status) = status else { return Ok(()) };
    let code = status
        .child_text("dmStatusCode")
        .or_else(|| status.child_text("dbStatusCode"))
        .unwrap_or_default();
    if code == "0000" || code.is_empty() {
        return Ok(());
    }
    // "Some messages were not sent": the reasons are per recipient.
    if code == "0004" && body.name == "CreateMultipleMessageResponse" {
        return Ok(());
    }
    Err(Error::Isds {
        code,
        text: status
            .child_text("dmStatusMessage")
            .or_else(|| status.child_text("dbStatusMessage"))
            .unwrap_or_default(),
    })
}

/// Parses ISDS date (`2026-10-27`) used in some responses.
pub fn parse_date(s: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_reads_are_sent_twice() {
        for op in ["GetListOfReceivedMessages", "MessageDownload", "SignedMessageDownload", "SignedSentMessageDownload", "MarkMessageAsDownloaded", "GetOwnerInfoFromLogin", "ISDSSearch3", "CheckDataBox", "PDZSendInfo", "AuthenticateMessage", "AuthenticateBigMessage"] {
            assert!(safe_to_repeat(op), "{op}");
        }
        for op in ["CreateMessage", "CreateMultipleMessage", "ChangeISDSPassword", "ChangePasswordOTP", "SendSMSCode", "EraseMessage", "DeleteDataBoxUser2", "UpdateDataBoxUser2"] {
            assert!(!safe_to_repeat(op), "{op}");
        }
    }

    #[test]
    fn status_ok_and_error() {
        let ok =
            xml::parse(b"<r><dmStatus><dmStatusCode>0000</dmStatusCode></dmStatus></r>").unwrap();
        assert!(check_status(&ok).is_ok());
        let err = xml::parse(
            b"<r><dmStatus><dmStatusCode>1219</dmStatusCode><dmStatusMessage>x</dmStatusMessage></dmStatus></r>",
        )
        .unwrap();
        assert!(matches!(check_status(&err), Err(Error::Isds { code, .. }) if code == "1219"));
    }

    #[test]
    fn parses_search_results() {
        let body = xml::parse(
            r#"<p:ISDSSearch2Response xmlns:p="http://isds.czechpoint.cz/v20">
              <p:totalCount>1</p:totalCount><p:lastPage>true</p:lastPage>
              <p:dbResults><p:dbResult>
                <p:dbID>4h6aibd</p:dbID><p:dbType>OVM</p:dbType>
                <p:dbName>Finanční úřad</p:dbName><p:dbICO>72080043</p:dbICO>
                <p:dbEffectiveOVM>true</p:dbEffectiveOVM><p:dbSendOptions>ALL</p:dbSendOptions>
              </p:dbResult></p:dbResults>
              <p:dbStatus><p:dbStatusCode>0000</p:dbStatusCode></p:dbStatus>
            </p:ISDSSearch2Response>"#
                .as_bytes(),
        )
        .unwrap();
        let page = parse_search(&body);
        assert_eq!(page.total, 1);
        assert_eq!(page.entries[0].box_id, "4h6aibd");
        assert!(page.entries[0].is_authority);
    }

    #[test]
    fn builds_create_message() {
        let m = OutgoingMessage {
            recipient_box_id: "4h6aibd".into(),
            annotation: "Odpověď <test>".into(),
            sender_ref_number: Some("NS-1".into()),
            allow_subst_delivery: true,
            files: vec![
                OutgoingFile {
                    name: "a.pdf".into(),
                    mime_type: "application/pdf".into(),
                    content: b"x".to_vec(),
                },
                OutgoingFile {
                    name: "b.txt".into(),
                    mime_type: "text/plain".into(),
                    content: b"y".to_vec(),
                },
            ],
            ..Default::default()
        };
        let mut pdz = m.clone();
        pdz.dm_type = Some("I".into());
        pdz.publish_own_id = Some(true);
        let doc = xml::parse(
            format!("<r>{}</r>", create_message_body(&pdz))
                .replace("isds:", "")
                .as_bytes(),
        )
        .unwrap();
        let env = doc.find("dmEnvelope").unwrap();
        assert_eq!(env.attr("dmType"), Some("I"));
        assert_eq!(env.children.last().unwrap().name, "dmPublishOwnID");
        let body = create_message_body(&m);
        let doc = xml::parse(format!("<r xmlns:isds=\"x\">{body}</r>").as_bytes()).unwrap();
        let env = doc.find("dmEnvelope").unwrap();
        let names: Vec<_> = env.children.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "dbIDRecipient",
                "dmAnnotation",
                "dmSenderRefNumber",
                "dmPersonalDelivery",
                "dmAllowSubstDelivery"
            ]
        );
        assert_eq!(
            env.child_text("dmAnnotation").as_deref(),
            Some("Odpověď <test>")
        );
        let files: Vec<_> = doc
            .find("dmFiles")
            .unwrap()
            .children_named("dmFile")
            .collect();
        assert_eq!(files[0].attr("dmFileMetaType"), Some("main"));
        assert_eq!(files[1].attr("dmFileMetaType"), Some("enclosure"));
        assert_eq!(
            files[0].child_text("dmEncodedContent").as_deref(),
            Some("eA==")
        );
        assert_eq!(mime_for("Smlouva.PDF"), "application/pdf");
    }

    #[test]
    fn parses_isds_search3_results() {
        // Sample of WS_vyhledavani_datovych_schranek, chapter 2.2 (with the
        // mismatched dbidOVM tags of the document fixed).
        let body = xml::parse(
            r#"<tns:ISDSSearch3Response xmlns:tns="http://isds.czechpoint.cz/v30"
                xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
              <tns:totalCount>10</tns:totalCount>
              <tns:currentCount>2</tns:currentCount>
              <tns:position>4</tns:position>
              <tns:lastPage>0</tns:lastPage>
              <tns:dbResults>
                <tns:dbResult>
                  <tns:dbID>d43s6xx</tns:dbID>
                  <tns:dbType>PO</tns:dbType>
                  <tns:dbName>Smutné s.r.o</tns:dbName>
                  <tns:dbAddress>Hlavní nám. 2, 65432 Podešice, CZ</tns:dbAddress>
                  <tns:dbBiDate xsi:nil="true"> </tns:dbBiDate>
                  <tns:dbICO>87654321</tns:dbICO>
                  <tns:dbIdOVM xsi:nil="true"></tns:dbIdOVM>
                  <tns:dbSendOptions>ALL</tns:dbSendOptions>
                </tns:dbResult>
                <tns:dbResult>
                  <tns:dbID>seymrkx</tns:dbID>
                  <tns:dbType>OVM_PO </tns:dbType>
                  <tns:dbName>Vysoká škola kouzel</tns:dbName>
                  <tns:dbAddress>Hlavní 123/432, 65432 Podešice okres Strašice, CZ</tns:dbAddress>
                  <tns:dbBiDate xsi:nil="true"> </tns:dbBiDate>
                  <tns:dbICO>65432112</tns:dbICO>
                  <tns:dbIdOVM>65432112</tns:dbIdOVM>
                  <tns:dbSendOptions>NONE</tns:dbSendOptions>
                </tns:dbResult>
              </tns:dbResults>
              <tns:dbStatus>
                <tns:dbStatusCode>0000</tns:dbStatusCode>
                <tns:dbStatusMessage>Operace proběhla úspěšně</tns:dbStatusMessage>
              </tns:dbStatus>
            </tns:ISDSSearch3Response>"#
                .as_bytes(),
        )
        .unwrap();
        assert!(check_status(&body).is_ok());
        let page = parse_search(&body);
        assert_eq!(page.total, 10);
        assert!(!page.last_page, "lastPage 0 means more pages");
        assert_eq!(page.entries.len(), 2);
        let (po, ovm) = (&page.entries[0], &page.entries[1]);
        assert_eq!(po.box_id, "d43s6xx");
        assert!(!po.is_authority);
        assert_eq!(po.id_ovm, None);
        assert_eq!(po.send_options.as_deref(), Some("ALL"));
        assert!(ovm.is_authority);
        assert_eq!(ovm.box_type.as_deref(), Some("OVM_PO"));
        assert_eq!(ovm.id_ovm.as_deref(), Some("65432112"));
        let last = xml::parse(b"<r><lastPage>1</lastPage></r>").unwrap();
        assert!(parse_search(&last).last_page);
        assert_eq!(SearchType::IdOvm.as_str(), "IDOVM");
    }

    fn sample_message() -> OutgoingMessage {
        OutgoingMessage {
            annotation: "Oběžník".into(),
            to_hands: Some("Jan Novák".into()),
            sender_ref_number: Some("NS-2".into()),
            allow_subst_delivery: true,
            files: vec![OutgoingFile {
                name: "a.pdf".into(),
                mime_type: "application/pdf".into(),
                content: b"x".to_vec(),
            }],
            ..Default::default()
        }
    }

    #[test]
    fn builds_create_multiple_message() {
        let m = sample_message();
        let body = create_multiple_body(&m, &["abc1234".into(), " def5678 ".into()]);
        let doc = xml::parse(format!("<r>{}</r>", body.replace("isds:", "")).as_bytes()).unwrap();
        let names: Vec<_> = doc.children.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["dmRecipients", "dmEnvelope", "dmFiles"]);
        let recips: Vec<_> = doc
            .child("dmRecipients")
            .unwrap()
            .children_named("dmRecipient")
            .collect();
        assert_eq!(recips.len(), 2);
        assert_eq!(recips[1].child_text("dbIDRecipient").as_deref(), Some("def5678"));
        assert_eq!(recips[0].child_text("dmToHands").as_deref(), Some("Jan Novák"));
        let env = doc.child("dmEnvelope").unwrap();
        assert!(env.child("dbIDRecipient").is_none() && env.child("dmToHands").is_none());
        assert_eq!(env.children[0].name, "dmAnnotation");
        assert_eq!(env.child_text("dmSenderRefNumber").as_deref(), Some("NS-2"));
        // Without K rukám each recipient carries a nil element, as the schema wants.
        let mut plain = m.clone();
        plain.to_hands = None;
        assert!(create_multiple_body(&plain, &["abc1234".into()])
            .contains(r#"<isds:dmToHands xsi:nil="true"/>"#));
        // The single-recipient envelope is unchanged.
        let mut one = m;
        one.recipient_box_id = "abc1234".into();
        assert!(create_message_body(&one)
            .starts_with("<isds:dmEnvelope><isds:dbIDRecipient>abc1234</isds:dbIDRecipient><isds:dmToHands>"));
    }

    #[test]
    fn reads_create_multiple_message_results() {
        // Sample of WS_manipulace_s_datovymi_zpravami, chapter 2.2.
        let body = xml::parse(
            r#"<p:CreateMultipleMessageResponse xmlns:p="http://isds.czechpoint.cz/v20">
               <p:dmMultipleStatus>
                  <p:dmSingleStatus>
                     <p:dmStatus>
                        <p:dmStatusCode>1233</p:dmStatusCode>
                        <p:dmStatusMessage>Odesilatel ani příjemce datové zprávy není OVM a zpráva je označena jako nekomerční.</p:dmStatusMessage>
                     </p:dmStatus>
                  </p:dmSingleStatus>
                  <p:dmSingleStatus>
                     <p:dmID>1835603</p:dmID>
                     <p:dmStatus>
                        <p:dmStatusCode>0000</p:dmStatusCode>
                        <p:dmStatusMessage>Provedeno úspěšně.</p:dmStatusMessage>
                     </p:dmStatus>
                  </p:dmSingleStatus>
               </p:dmMultipleStatus>
               <p:dmStatus>
                  <p:dmStatusCode>0004</p:dmStatusCode>
                  <p:dmStatusMessage>Některé datové zprávy nebyly úspěšně odeslány.</p:dmStatusMessage>
               </p:dmStatus>
            </p:CreateMultipleMessageResponse>"#
                .as_bytes(),
        )
        .unwrap();
        // 0004 is not a failure of the call; the first recipient's error is not either.
        assert!(check_status(&body).is_ok());
        let list = parse_multiple(&body, 2).unwrap();
        assert!(matches!(&list[0], Err(Error::Isds { code, .. }) if code == "1233"));
        assert_eq!(list[1].as_ref().unwrap(), "1835603");
        assert!(parse_multiple(&body, 3).is_err());
        // An error before sending anything is an error of the whole call.
        let refused = xml::parse(
            br#"<p:CreateMultipleMessageResponse xmlns:p="http://isds.czechpoint.cz/v20">
               <p:dmStatus><p:dmStatusCode>1252</p:dmStatusCode>
               <p:dmStatusMessage>Nalezen virus</p:dmStatusMessage></p:dmStatus>
            </p:CreateMultipleMessageResponse>"#,
        )
        .unwrap();
        assert!(matches!(check_status(&refused), Err(Error::Isds { code, .. }) if code == "1252"));
    }

    #[test]
    fn decodes_cid() {
        assert_eq!(percent_decode("a%40b"), "a@b");
        assert_eq!(percent_decode("plain"), "plain");
    }
}
