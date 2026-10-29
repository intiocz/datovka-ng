//! Further ISDS operations: verification, author, erasing, box information,
//! credit, data vault, users, password. Results are JSON for display.

use base64::Engine;
use serde_json::{Map, Value};

use super::{Client, Service};
use crate::error::{Error, Result};
use crate::xml::{escape, Element};

/// Converts an XML element to JSON: leaves become strings, repeated children
/// become arrays, attributes are prefixed with `@`.
pub(crate) fn to_json(el: &Element) -> Value {
    if el.attr("nil") == Some("true") {
        return Value::Null;
    }
    if el.children.is_empty() && el.attrs.iter().all(|(k, _)| k.starts_with("xmlns")) {
        let t = el.text.trim();
        return if t.is_empty() || el.attr("nil") == Some("true") {
            Value::Null
        } else {
            Value::String(t.to_string())
        };
    }
    let mut map = Map::new();
    for (k, v) in &el.attrs {
        if k != "nil" && !k.starts_with("xmlns") {
            map.insert(format!("@{k}"), Value::String(v.clone()));
        }
    }
    for c in &el.children {
        let v = to_json(c);
        match map.get_mut(&c.name) {
            Some(Value::Array(a)) => a.push(v),
            Some(prev) => {
                let p = prev.take();
                *prev = Value::Array(vec![p, v]);
            }
            None => {
                map.insert(c.name.clone(), v);
            }
        }
    }
    Value::Object(map)
}

fn without_status(mut v: Value) -> Value {
    if let Value::Object(m) = &mut v {
        m.remove("dmStatus");
        m.remove("dbStatus");
    }
    v
}

fn dm_id(id: &str) -> String {
    format!("<isds:dmID>{}</isds:dmID>", escape(id))
}

/// One message of the erased-messages list (`dmRecord`).
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ErasedMessage {
    pub dm_id: String,
    /// PDZ subtype (`K`, `I`, …); empty for a public message.
    pub dm_type: String,
    pub sender_box_id: String,
    pub sender: String,
    pub recipient_box_id: String,
    pub recipient: String,
    pub annotation: String,
    pub status: String,
    pub delivery_time: String,
    pub acceptance_time: String,
}

/// Reads the ZIP of `PickUpAsyncResponse` (one XML file of `dmRecords`).
pub fn parse_erased_zip(zip: &[u8]) -> Result<Vec<ErasedMessage>> {
    use std::io::Read;
    let bad = |e: &dyn std::fmt::Display| Error::Xml(format!("seznam smazaných zpráv: {e}"));
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip)).map_err(|e| bad(&e))?;
    let mut text = String::new();
    archive
        .by_index(0)
        .map_err(|e| bad(&e))?
        .read_to_string(&mut text)
        .map_err(|e| bad(&e))?;
    if text.contains("Too many records") {
        return Err(Error::Isds {
            code: "too_many".into(),
            text: "zpráv je víc než 5000, zvolte kratší období (jeden měsíc)".into(),
        });
    }
    let doc = crate::xml::parse(text.as_bytes())?;
    let field = |r: &Element, k: &str| r.child_text(k).unwrap_or_default();
    Ok(doc
        .children_named("dmRecord")
        .map(|r| ErasedMessage {
            dm_id: field(r, "dmID"),
            dm_type: r.attr("dmType").unwrap_or_default().to_string(),
            sender_box_id: field(r, "dbIDSender"),
            sender: field(r, "dmSender"),
            recipient_box_id: field(r, "dbIDRecipient"),
            recipient: field(r, "dmRecipient"),
            annotation: field(r, "dmAnnotation"),
            status: field(r, "dmMessageStatus"),
            delivery_time: field(r, "dmDeliveryTime"),
            acceptance_time: field(r, "dmAcceptanceTime"),
        })
        .collect())
}

/// `dmHash` of a message as stored in its signed content.
pub fn zfo_hash(zfo: &[u8]) -> Result<(String, Option<String>)> {
    let root = crate::xml::parse(&crate::zfo::signed_content(zfo)?)?;
    let h = root
        .find("dmHash")
        .ok_or_else(|| Error::Zfo("ZFO neobsahuje dmHash".into()))?;
    Ok((
        h.text.split_whitespace().collect(),
        h.attr("algorithm").map(str::to_string),
    ))
}

/// `dmAuthResult` of `Authenticate[Big]Message` (xs:boolean).
fn auth_result(body: &Element) -> Result<bool> {
    match body.child_text("dmAuthResult").as_deref() {
        Some("true" | "1") => Ok(true),
        Some("false" | "0") => Ok(false),
        _ => Err(Error::Xml("odpověď bez dmAuthResult".into())),
    }
}

/// Whether a message ZFO is a high-volume message (`dmVODZ` in the envelope).
fn is_vodz(zfo: &[u8]) -> bool {
    crate::zfo::parse_message(zfo).is_ok_and(|m| m.envelope.vodz == Some(true))
}

/// `dbState` of `CheckDataBoxResponse`.
fn box_state(body: &Element) -> Result<u8> {
    body.child_text("dbState")
        .and_then(|s| s.parse().ok())
        .filter(|s| *s > 0)
        .ok_or_else(|| Error::Xml("odpověď bez stavu schránky".into()))
}

/// Czech description of a `CheckDataBox` state.
pub fn box_state_text(state: u8) -> &'static str {
    match state {
        1 => "schránka je přístupná",
        2 => "schránka je dočasně znepřístupněná",
        3 => "schránka ještě není zpřístupněná",
        4 => "schránka je trvale znepřístupněná",
        5 => "schránka je zrušená",
        _ => "stav schránky je neznámý",
    }
}

fn pdz_send_info_body(box_id: &str, kind: &str) -> String {
    format!(
        "<isds:dbId>{}</isds:dbId><isds:PDZType>{}</isds:PDZType>",
        escape(box_id.trim()),
        escape(kind)
    )
}

/// Namespace and path of the password service for OTP logins.
pub(super) const ASWS_NS: &str = "http://isds.czechpoint.cz/v20/asws";
pub(super) const ASWS_PATH: &str = "asws/changePassword";

/// Second factor of a password change for a box logging in with a code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Otp {
    /// Code from an SMS (TOTP).
    Sms,
    /// Code from an app or token (HOTP).
    App,
}

pub(super) fn change_password_otp_body(old: &str, new: &str, otp: Otp) -> String {
    format!(
        "<isds:dbOldPassword>{}</isds:dbOldPassword><isds:dbNewPassword>{}</isds:dbNewPassword><isds:dbOTPType>{}</isds:dbOTPType>",
        escape(old),
        escape(new),
        if otp == Otp::Sms { "TOTP" } else { "HOTP" }
    )
}

/// Client of the password service: name and password (plus the code) go
/// straight to it with each request, no session.
fn asws_client(username: &str, secret: String, test_env: bool) -> Result<(Client, String)> {
    let www = if test_env { super::TEST_WWW } else { super::PROD_WWW };
    let c = Client {
        http: super::http_client(false)?,
        base: www.to_string(),
        vodz_base: www.to_string(),
        basic: Some((username.to_string(), secret)),
    };
    Ok((c, format!("{www}{ASWS_PATH}")))
}

/// Has ISDS send an SMS code for [`change_password_otp`] (`SendSMSCode`).
pub async fn send_sms_code(username: &str, password: &str, test_env: bool) -> Result<()> {
    let (c, url) = asws_client(username, password.to_string(), test_env)?;
    c.call_ns(&url, ASWS_NS, "SendSMSCode", "").await?;
    Ok(())
}

/// Changes the password of a box that logs in with password and code
/// (`ChangePasswordOTP`); the old password and the code authenticate it.
pub async fn change_password_otp(
    username: &str,
    old: &str,
    new: &str,
    code: &str,
    otp: Otp,
    test_env: bool,
) -> Result<()> {
    let (c, url) = asws_client(username, format!("{old}{}", code.trim()), test_env)?;
    c.call_ns(
        &url,
        ASWS_NS,
        "ChangePasswordOTP",
        &change_password_otp_body(old, new, otp),
    )
    .await?;
    Ok(())
}

/// Fields of `tDbUserInfoExt2` in schema order.
const USER_FIELDS: &[&str] = &[
    "aifoIsds",
    "pnGivenNames",
    "pnLastName",
    "adCode",
    "adCity",
    "adDistrict",
    "adStreet",
    "adNumberInStreet",
    "adNumberInMunicipality",
    "adZipCode",
    "adState",
    "biDate",
    "isdsID",
    "userType",
    "userPrivils",
    "ic",
    "firmName",
    "caStreet",
    "caCity",
    "caZipCode",
    "caState",
];

/// Builds `tDbUserInfoExt2` content from a JSON object with the same field
/// names (as returned by `GetDataBoxUsers2`); missing fields are nil.
pub(crate) fn user_info_xml(user: &Value) -> String {
    let mut out = String::new();
    for f in USER_FIELDS {
        match user.get(*f) {
            Some(Value::String(v)) if !v.is_empty() => {
                out += &format!("<isds:{f}>{}</isds:{f}>", escape(v))
            }
            Some(Value::Number(n)) => out += &format!("<isds:{f}>{n}</isds:{f}>"),
            Some(Value::Bool(b)) => out += &format!("<isds:{f}>{b}</isds:{f}>"),
            // The only element that may not be nil; ISDS sets it itself.
            _ if *f == "aifoIsds" => out += "<isds:aifoIsds>false</isds:aifoIsds>",
            _ => out += &format!(r#"<isds:{f} xsi:nil="true"/>"#),
        }
    }
    out
}

impl Client {
    /// Adds a user (e.g. an entrusted person) to a data box.
    pub async fn add_user(&self, box_id: &str, user: &Value) -> Result<Value> {
        let inner = format!(
            "<isds:dbID>{}</isds:dbID><isds:dbUserInfo>{}</isds:dbUserInfo>",
            escape(box_id),
            user_info_xml(user)
        );
        self.op_json(Service::DsManage, "AddDataBoxUser2", &inner)
            .await
    }

    /// Replaces a user's data (typically privileges).
    pub async fn update_user(&self, box_id: &str, isds_id: &str, user: &Value) -> Result<()> {
        let inner = format!(
            "<isds:dbID>{}</isds:dbID><isds:isdsID>{}</isds:isdsID><isds:dbNewUserInfo>{}</isds:dbNewUserInfo>",
            escape(box_id),
            escape(isds_id),
            user_info_xml(user)
        );
        self.call(Service::DsManage, "UpdateDataBoxUser2", &inner)
            .await?;
        Ok(())
    }

    pub async fn delete_user(&self, box_id: &str, isds_id: &str) -> Result<()> {
        let inner = format!(
            "<isds:dbID>{}</isds:dbID><isds:isdsID>{}</isds:isdsID>",
            escape(box_id),
            escape(isds_id)
        );
        self.call(Service::DsManage, "DeleteDataBoxUser2", &inner)
            .await?;
        Ok(())
    }

    /// Calls any operation and returns its response body as JSON.
    pub async fn op_json(&self, service: Service, op: &str, inner: &str) -> Result<Value> {
        let r = self.call(service, op, inner).await?;
        Ok(without_status(to_json(&r.body)))
    }

    /// Lets ISDS confirm that a ZFO file is an authentic, unaltered message.
    pub async fn authenticate_message(&self, zfo: &[u8]) -> Result<bool> {
        let inner = format!(
            "<isds:dmMessage>{}</isds:dmMessage>",
            base64::engine::general_purpose::STANDARD.encode(zfo)
        );
        let r = self
            .call(Service::Dz, "AuthenticateMessage", &inner)
            .await?;
        auth_result(&r.body)
    }

    /// [`authenticate_message`](Self::authenticate_message), or
    /// `AuthenticateBigMessage` for a high-volume message (ISDS refuses the
    /// other one). Returns the result and the operation used.
    pub async fn authenticate_any(&self, zfo: &[u8]) -> Result<(bool, &'static str)> {
        if is_vodz(zfo) {
            let ok = self.authenticate_big_message(zfo).await?;
            Ok((ok, "AuthenticateBigMessage"))
        } else {
            Ok((self.authenticate_message(zfo).await?, "AuthenticateMessage"))
        }
    }

    /// State of a data box (`CheckDataBox`): 1 accessible, 2 temporarily
    /// inaccessible, 3 not yet accessible, 4 permanently inaccessible,
    /// 5 deleted. Only 1 can receive messages.
    pub async fn check_box(&self, box_id: &str) -> Result<u8> {
        let inner = format!("<isds:dbID>{}</isds:dbID>", escape(box_id.trim()));
        let r = self.call(Service::Df, "CheckDataBox", &inner).await?;
        box_state(&r.body)
    }

    /// Whether this box can send a commercial message (PDZ) to `box_id`
    /// (`PDZSendInfo`). `kind` is `Normal`, `Init` (initiating, needs a
    /// contract) or `VoDZ`.
    pub async fn pdz_send_info(&self, box_id: &str, kind: &str) -> Result<bool> {
        let r = self
            .call(Service::Df, "PDZSendInfo", &pdz_send_info_body(box_id, kind))
            .await?;
        Ok(matches!(
            r.body.child_text("PDZsiResult").as_deref(),
            Some("true" | "1")
        ))
    }

    /// Has ISDS re-sign a stored ZFO with a fresh time stamp (the original's
    /// time stamp renewal). Returns the new ZFO and its validity date.
    pub async fn resign_document(&self, zfo: &[u8]) -> Result<(Vec<u8>, Option<String>)> {
        let inner = format!(
            "<isds:dmDoc>{}</isds:dmDoc>",
            base64::engine::general_purpose::STANDARD.encode(zfo)
        );
        let r = self
            .call(Service::Dz, "Re-signISDSDocument", &inner)
            .await?;
        let doc = r.binary("dmResultDoc")?;
        Ok((doc, r.body.child_text("dmValidTo")))
    }

    pub async fn message_author(&self, id: &str) -> Result<Value> {
        self.op_json(Service::Dx, "GetMessageAuthor2", &dm_id(id))
            .await
    }

    /// Deletes a message from ISDS (allowed for messages already in the vault
    /// or delivered; the local copy stays).
    pub async fn erase_message(&self, id: &str, incoming: bool) -> Result<()> {
        let inner = format!("{}<isds:dmIncoming>{incoming}</isds:dmIncoming>", dm_id(id));
        self.call(Service::Dx, "EraseMessage", &inner).await?;
        Ok(())
    }

    pub async fn owner_info2(&self) -> Result<Value> {
        self.op_json(
            Service::DsManage,
            "GetOwnerInfoFromLogin2",
            "<isds:dbDummy/>",
        )
        .await
    }

    pub async fn user_info2(&self) -> Result<Value> {
        self.op_json(
            Service::DsManage,
            "GetUserInfoFromLogin2",
            "<isds:dbDummy/>",
        )
        .await
    }

    pub async fn change_password(&self, old: &str, new: &str) -> Result<()> {
        let inner = format!(
            "<isds:dbOldPassword>{}</isds:dbOldPassword><isds:dbNewPassword>{}</isds:dbNewPassword>",
            escape(old),
            escape(new)
        );
        self.call(Service::DsManage, "ChangeISDSPassword", &inner)
            .await?;
        Ok(())
    }

    /// Credit for commercial messages and its history.
    pub async fn credit_info(&self, box_id: &str) -> Result<Value> {
        let inner = format!(
            r#"<isds:dbID>{}</isds:dbID><isds:ciFromDate xsi:nil="true"/><isds:ciTodate xsi:nil="true"/>"#,
            escape(box_id)
        );
        self.op_json(Service::Df, "DataBoxCreditInfo", &inner).await
    }

    /// Data vault (Datový trezor) subscription.
    pub async fn dt_info(&self, box_id: &str) -> Result<Value> {
        let inner = format!("<isds:dbId>{}</isds:dbId>", escape(box_id));
        self.op_json(Service::Df, "DTInfo", &inner).await
    }

    /// How the box may send commercial messages (PDZ).
    pub async fn pdz_info(&self, box_id: &str) -> Result<Value> {
        let inner = format!("<isds:PDZSender>{}</isds:PDZSender>", escape(box_id));
        self.op_json(Service::Df, "PDZInfo", &inner).await
    }

    pub async fn box_users(&self, box_id: &str) -> Result<Value> {
        let inner = format!("<isds:dbID>{}</isds:dbID>", escape(box_id));
        self.op_json(Service::DsManage, "GetDataBoxUsers2", &inner)
            .await
    }

    /// Asks ISDS to prepare the list of messages erased in one month, or in
    /// a whole year when `month` is `None`, and returns the id to pick it up
    /// with. ISDS accepts only periods at least three months back.
    pub async fn request_erased(&self, year: i32, month: Option<u32>, received: bool) -> Result<String> {
        let period = match month {
            Some(m) => format!("<isds:dmYear>{year}</isds:dmYear><isds:dmMonth>{m}</isds:dmMonth>"),
            None => format!("<isds:dmYear>{year}</isds:dmYear>"),
        };
        let inner = format!(
            "{period}<isds:dmMessageType>{}</isds:dmMessageType><isds:dmOutFormat>XML</isds:dmOutFormat>",
            if received { "RECEIVED" } else { "SENT" }
        );
        let r = self.call(Service::Dx, "GetListOfErasedMessages", &inner).await?;
        r.body
            .find("asyncID")
            .map(|e| e.text.trim().to_string())
            .filter(|id| !id.is_empty())
            .ok_or_else(|| Error::Xml("odpověď bez asyncID".into()))
    }

    /// The prepared ZIP, `None` while ISDS is still building it (2352).
    pub async fn pick_up_erased(&self, id: &str) -> Result<Option<Vec<u8>>> {
        let inner = format!(
            "<isds:asyncID>{}</isds:asyncID><isds:asyncReqType>LIST_ERASED</isds:asyncReqType>",
            escape(id)
        );
        match self.call(Service::Dx, "PickUpAsyncResponse", &inner).await {
            Ok(r) => Ok(Some(r.binary("asyncResponse")?)),
            Err(Error::Isds { code, .. }) if code == "2352" => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Messages erased from ISDS in a month (or year): asks for the list,
    /// waits for it up to `wait` and unpacks it.
    pub async fn erased_messages(
        &self,
        year: i32,
        month: Option<u32>,
        received: bool,
        wait: std::time::Duration,
    ) -> Result<Vec<ErasedMessage>> {
        let id = self.request_erased(year, month, received).await?;
        let until = std::time::Instant::now() + wait;
        loop {
            if let Some(zip) = self.pick_up_erased(&id).await? {
                return parse_erased_zip(&zip);
            }
            if std::time::Instant::now() >= until {
                return Err(Error::Isds {
                    code: "2352".into(),
                    text: "ISDS seznam ještě připravuje, zkuste to za chvíli znovu".into(),
                });
            }
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        }
    }

    /// State changes of messages since a time (RFC 3339).
    pub async fn state_changes(&self, from: &str) -> Result<Value> {
        let inner = format!(
            r#"<isds:dmFromTime>{}</isds:dmFromTime><isds:dmToTime xsi:nil="true"/>"#,
            escape(from)
        );
        self.op_json(Service::Dx, "GetMessageStateChanges", &inner)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn converts_xml_to_json() {
        let el = crate::xml::parse(
            br#"<r><a>1</a><b x="y"><c>2</c><c>3</c></b><n xsi:nil="true"/></r>"#,
        )
        .unwrap();
        assert_eq!(
            to_json(&el),
            json!({"a": "1", "b": {"@x": "y", "c": ["2", "3"]}, "n": null})
        );
    }

    #[test]
    fn builds_user_info_in_schema_order() {
        let x = user_info_xml(
            &json!({"pnLastName": "Novák", "userPrivils": 255, "userType": "ENTRUSTED_USER"}),
        );
        let i = |f: &str| x.find(f).unwrap();
        assert!(i("aifoIsds") < i("pnLastName") && i("pnLastName") < i("userPrivils"));
        assert!(x.contains("<isds:userPrivils>255</isds:userPrivils>"));
        assert!(x.contains(r#"<isds:caState xsi:nil="true"/>"#));
    }

    fn parse(xml: &str) -> Element {
        crate::xml::parse(xml.as_bytes()).unwrap()
    }

    #[test]
    fn reads_box_state() {
        // WS_vyhledavani_datovych_schranek, chapter 2.3.
        let ok = parse(
            r#"<p:CheckDataBoxResponse xmlns:p="http://isds.czechpoint.cz/v20">
              <p:dbState>1</p:dbState>
              <p:dbStatus><p:dbStatusCode>0000</p:dbStatusCode>
              <p:dbStatusMessage>Provedeno úspěšně.</p:dbStatusMessage></p:dbStatus>
            </p:CheckDataBoxResponse>"#,
        );
        assert_eq!(box_state(&ok).unwrap(), 1);
        let gone = parse("<r><dbState>5</dbState></r>");
        assert_eq!(box_state(&gone).unwrap(), 5);
        assert_eq!(box_state_text(5), "schránka je zrušená");
        assert!(box_state(&parse("<r><dbState>0</dbState></r>")).is_err());
        let missing = parse(
            r#"<p:CheckDataBoxResponse xmlns:p="http://isds.czechpoint.cz/v20">
              <p:dbStatus><p:dbStatusCode>5001</p:dbStatusCode>
              <p:dbStatusMessage>Schránka neexistuje</p:dbStatusMessage></p:dbStatus>
            </p:CheckDataBoxResponse>"#,
        );
        assert!(
            matches!(super::super::check_status(&missing), Err(Error::Isds { code, .. }) if code == "5001")
        );
    }

    #[test]
    fn builds_pdz_send_info() {
        let x = pdz_send_info_body(" abc1234 ", "Init");
        assert_eq!(
            x,
            "<isds:dbId>abc1234</isds:dbId><isds:PDZType>Init</isds:PDZType>"
        );
        let r = parse(
            r#"<p:PDZSendInfoResponse xmlns:p="http://isds.czechpoint.cz/v20">
              <p:PDZsiResult>true</p:PDZsiResult>
              <p:dbStatus><p:dbStatusCode>0000</p:dbStatusCode><p:dbStatusMessage/></p:dbStatus>
            </p:PDZSendInfoResponse>"#,
        );
        assert_eq!(r.child_text("PDZsiResult").as_deref(), Some("true"));
    }

    #[test]
    fn reads_auth_result() {
        assert!(auth_result(&parse("<r><dmAuthResult>true</dmAuthResult></r>")).unwrap());
        assert!(auth_result(&parse("<r><dmAuthResult>1</dmAuthResult></r>")).unwrap());
        assert!(!auth_result(&parse("<r><dmAuthResult>false</dmAuthResult></r>")).unwrap());
        assert!(auth_result(&parse(r#"<r><dmAuthResult xsi:nil="true"/></r>"#)).is_err());
        assert!(!is_vodz(b"not a zfo"));
    }

    #[test]
    fn builds_change_password_otp() {
        let x = change_password_otp_body("Staré<1", "Nové&2", Otp::Sms);
        let doc = parse(&format!("<r>{}</r>", x.replace("isds:", "")));
        let names: Vec<_> = doc.children.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["dbOldPassword", "dbNewPassword", "dbOTPType"]);
        assert_eq!(doc.child_text("dbOldPassword").as_deref(), Some("Staré<1"));
        assert_eq!(doc.child_text("dbNewPassword").as_deref(), Some("Nové&2"));
        assert_eq!(doc.child_text("dbOTPType").as_deref(), Some("TOTP"));
        assert!(change_password_otp_body("a", "b", Otp::App).contains(">HOTP<"));
        let (c, url) = asws_client("user", "heslo123456".into(), true).unwrap();
        assert_eq!(url, "https://www.datovka-test.gov.cz/asws/changePassword");
        assert_eq!(
            c.basic,
            Some(("user".to_string(), "heslo123456".to_string()))
        );
    }

    #[test]
    fn reads_zfo_hash() {
        let Ok(zfo) = std::fs::read("../reference/datovka-qt/tests/data/DZ_6452235.zfo") else {
            return;
        };
        let (h, alg) = zfo_hash(&zfo).unwrap();
        assert!(!h.is_empty());
        assert!(alg.is_some());
    }
}

#[cfg(test)]
mod erased_tests {
    use super::*;
    use std::io::Write;

    fn zipped(name: &str, text: &str) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        let mut w = zip::ZipWriter::new(&mut out);
        w.start_file(name, zip::write::SimpleFileOptions::default())
            .unwrap();
        w.write_all(text.as_bytes()).unwrap();
        w.finish().unwrap();
        out.into_inner()
    }

    #[test]
    fn reads_the_erased_list_of_the_documentation() {
        // The sample of WS_manipulace_s_datovymi_zpravami, chapter 2.10.
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<q:dmRecords xmlns:q="http://isds.czechpoint.cz/v20">
    <q:dmRecord dmType="K">
        <q:dmID>1495213</q:dmID>
        <q:dbIDSender>kv62bqf</q:dbIDSender>
        <q:dmSender>&lt;Společnost pro potlačení zla &amp; Son&gt;</q:dmSender>
        <q:dbIDRecipient>9ky2eiu</q:dbIDRecipient>
        <q:dmRecipient>Jan Bohuslav Šimek</q:dmRecipient>
        <q:dmAnnotation>Faktura</q:dmAnnotation>
        <q:dmMessageStatus>6</q:dmMessageStatus>
        <q:dmDeliveryTime>2020-01-13T16:54:09.347+01:00</q:dmDeliveryTime>
        <q:dmAcceptanceTime>2020-01-15T09:30:19.231+01:00</q:dmAcceptanceTime>
    </q:dmRecord>
    <q:dmRecord>
        <q:dmID>1495552</q:dmID>
        <q:dbIDSender>kv62bqf</q:dbIDSender>
        <q:dmSender>&lt;Společnost pro potlačení zla &amp; Son&gt;</q:dmSender>
        <q:dbIDRecipient>asdv62b</q:dbIDRecipient>
        <q:dmRecipient>Ministerstvo kouzel</q:dmRecipient>
        <q:dmAnnotation>dotaz</q:dmAnnotation>
        <q:dmMessageStatus>6</q:dmMessageStatus>
        <q:dmDeliveryTime>2020-01-17T17:33:25.295+01:00</q:dmDeliveryTime>
        <q:dmAcceptanceTime></q:dmAcceptanceTime>
    </q:dmRecord>
</q:dmRecords>"#;
        let list = parse_erased_zip(&zipped("kv62bqf_7.xml", xml)).unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].dm_id, "1495213");
        assert_eq!(list[0].dm_type, "K");
        assert_eq!(list[0].sender, "<Společnost pro potlačení zla & Son>");
        assert_eq!(list[1].dm_type, "");
        assert_eq!(list[1].recipient, "Ministerstvo kouzel");
        assert_eq!(list[1].acceptance_time, "");
    }

    #[test]
    fn too_many_records_is_an_error_not_an_empty_list() {
        let zip = zipped("x.xml", "Too many records in the specified time window.");
        let err = parse_erased_zip(&zip).unwrap_err().to_string();
        assert!(err.contains("5000"), "{err}");
    }
}
