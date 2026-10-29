//! High-volume data messages (VoDZ, "velkoobjemové datové zprávy").
//!
//! Files are uploaded one by one (`UploadAttachment`, MTOM/XOP), the message
//! then references them by the returned attachment ID and hashes
//! (`CreateBigMessage` with `dmExtFile`). All operations live at `DS/vodz`
//! under a separate base URL (`ws2…` for password logins, the same
//! `www…/apps/` prefix as other services after an interactive login).
//!
//! Request layouts follow libdatovka (`isds_UploadAttachment_mtomxop`,
//! `isds_CreateBigMessage`, `insert_ext_file`, `isds_SignedBigMessageDownload`,
//! `isds_DownloadAttachment`, `isds_AuthenticateBigMessage`).

use std::sync::atomic::{AtomicU64, Ordering};

use base64::Engine;

use super::{envelope_element, Client, OutgoingMessage, Response, NS};
use crate::error::{Error, Result};
use crate::xml::escape;

/// Service path of VoDZ message operations.
const VODZ_PATH: &str = "DS/vodz";
/// Service path of `ArchiveISDSDocument` (same ws2 base as VoDZ).
const ARCH_PATH: &str = "DS/arch";
const SOAP12_NS: &str = "http://www.w3.org/2003/05/soap-envelope";
const XOP_NS: &str = "http://www.w3.org/2004/08/xop/include";
/// Content-IDs used by libdatovka for the SOAP part and the uploaded file.
const ROOT_CID: &str = "rootpart@soapui.org";
const ATT_CID: &str = "att_1";

/// ISDS status of `UploadAttachment` when its virus check timed out.
const AV_TIMEOUT: &str = "2046";

/// A file stored in ISDS by `UploadAttachment`, to be referenced by
/// `CreateBigMessage`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UploadedAttachment {
    /// `dmAttID` assigned by ISDS.
    pub id: String,
    pub hash1: String,
    pub hash1_alg: String,
    pub hash2: String,
    pub hash2_alg: String,
}

/// A file of a high-volume message (`DownloadAttachment`).
#[derive(Debug, Clone)]
pub struct DownloadedAttachment {
    pub name: String,
    pub mime_type: String,
    pub content: Vec<u8>,
}

/// SOAP 1.2 envelope used for MTOM/XOP requests.
fn soap12(op: &str, inner: &str) -> String {
    format!(
        concat!(
            r#"<?xml version="1.0" encoding="UTF-8"?>"#,
            r#"<soap:Envelope xmlns:soap="{soap}" xmlns:isds="{ns}">"#,
            r#"<soap:Body><isds:{op}>{inner}</isds:{op}></soap:Body></soap:Envelope>"#
        ),
        soap = SOAP12_NS,
        ns = NS,
        op = op,
        inner = inner
    )
}

/// Inner part of `UploadAttachment`: the file content is an XOP reference.
fn upload_body(name: &str, mime: &str) -> String {
    format!(
        concat!(
            r#"<isds:dmFile dmMimeType="{mime}" dmFileDescr="{name}">"#,
            "<isds:dmEncodedContent>",
            r#"<inc:Include xmlns:inc="{xop}" href="cid:{cid}"/>"#,
            "</isds:dmEncodedContent></isds:dmFile>"
        ),
        mime = escape(mime),
        name = escape(name),
        xop = XOP_NS,
        cid = ATT_CID,
    )
}

/// Value safe to put into a MIME header (quoted string).
fn header_value(s: &str) -> String {
    s.chars()
        .map(|c| {
            if matches!(c, '"' | '\r' | '\n' | '\\') {
                '_'
            } else {
                c
            }
        })
        .collect()
}

fn boundary() -> String {
    static N: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    format!("----=_Part_{nanos:x}_{}", N.fetch_add(1, Ordering::Relaxed))
}

/// `multipart/related` body of an MTOM/XOP upload: the SOAP part followed by
/// the raw file. Returns (HTTP Content-Type, body).
fn mtom_upload(soap: &str, name: &str, mime: &str, data: &[u8]) -> (String, Vec<u8>) {
    let b = boundary();
    let name = header_value(name);
    let mut body = Vec::with_capacity(soap.len() + data.len() + 1024);
    body.extend_from_slice(
        format!(
            concat!(
                "--{b}\r\n",
                "Content-Type: application/xop+xml; charset=UTF-8; type=\"application/soap+xml\"\r\n",
                "Content-Transfer-Encoding: 8bit\r\n",
                "Content-ID: <{root}>\r\n\r\n"
            ),
            b = b,
            root = ROOT_CID
        )
        .as_bytes(),
    );
    body.extend_from_slice(soap.as_bytes());
    body.extend_from_slice(
        format!(
            concat!(
                "\r\n--{b}\r\n",
                "Content-Type: {mime}; name=\"{name}\"\r\n",
                "Content-Transfer-Encoding: binary\r\n",
                "Content-ID: <{cid}>\r\n",
                "Content-Disposition: attachment; name=\"{name}\"; filename=\"{name}\"\r\n\r\n"
            ),
            b = b,
            mime = header_value(mime),
            name = name,
            cid = ATT_CID
        )
        .as_bytes(),
    );
    body.extend_from_slice(data);
    body.extend_from_slice(format!("\r\n--{b}--\r\n").as_bytes());
    let content_type = format!(
        concat!(
            r#"multipart/related; type="application/xop+xml"; start="<{root}>"; "#,
            r#"start-info="application/soap+xml"; action=""; boundary="{b}""#
        ),
        root = ROOT_CID,
        b = b
    );
    (content_type, body)
}

/// Inner part of `CreateBigMessage`: envelope and `dmExtFile` references.
/// The first attachment is the main document.
fn create_big_message_body(m: &OutgoingMessage, atts: &[UploadedAttachment]) -> String {
    let mut files = String::new();
    for (i, a) in atts.iter().enumerate() {
        files += &format!(
            concat!(
                r#"<isds:dmExtFile dmFileMetaType="{meta}" dmAttID="{id}" "#,
                r#"dmAttHash1="{h1}" dmAttHash1Alg="{a1}" "#,
                r#"dmAttHash2="{h2}" dmAttHash2Alg="{a2}"/>"#
            ),
            meta = if i == 0 { "main" } else { "enclosure" },
            id = escape(&a.id),
            h1 = escape(&a.hash1),
            a1 = escape(&a.hash1_alg),
            h2 = escape(&a.hash2),
            a2 = escape(&a.hash2_alg),
        );
    }
    format!(
        "{}<isds:dmFiles>{files}</isds:dmFiles>",
        envelope_element(m)
    )
}

fn parse_uploaded(r: &Response) -> Result<UploadedAttachment> {
    let b = &r.body;
    let id = b
        .child_text("dmAttID")
        .filter(|s| !s.is_empty())
        .ok_or_else(|| Error::Xml("odpověď bez dmAttID".into()))?;
    let hash = |n: &str| {
        let el = b.child(n);
        (
            el.map(|e| e.text.trim().to_string()).unwrap_or_default(),
            el.and_then(|e| e.attr("AttHashAlg"))
                .unwrap_or_default()
                .to_string(),
        )
    };
    let (hash1, hash1_alg) = hash("dmAttHash1");
    let (hash2, hash2_alg) = hash("dmAttHash2");
    Ok(UploadedAttachment {
        id,
        hash1,
        hash1_alg,
        hash2,
        hash2_alg,
    })
}

impl Client {
    fn vodz_url(&self) -> String {
        format!("{}{VODZ_PATH}", self.vodz_base)
    }

    /// SOAP 1.2 request asking for an MTOM/XOP response (large binary data).
    async fn call_vodz_xop(&self, op: &str, inner: &str) -> Result<Response> {
        let req = self
            .http
            .post(self.vodz_url())
            .header("Content-Type", "application/soap+xml; charset=utf-8")
            .header("Accept", "multipart/related")
            .header("SOAPAction", "")
            .body(soap12(op, inner));
        self.send(req).await
    }

    /// Uploads one file of a high-volume message (MTOM/XOP `UploadAttachment`).
    pub async fn upload_attachment(
        &self,
        name: &str,
        mime: &str,
        data: &[u8],
    ) -> Result<UploadedAttachment> {
        if data.is_empty() {
            return Err(Error::Isds {
                code: "files".into(),
                text: format!("příloha {name} je prázdná"),
            });
        }
        let soap = soap12("UploadAttachment", &upload_body(name, mime));
        let (content_type, body) = mtom_upload(&soap, name, mime, data);
        let upload = || {
            self.http
                .post(self.vodz_url())
                .header("Content-Type", &content_type)
                .header("Accept", "application/soap+xml,application/xml,text/xml")
                .header("SOAPAction", "")
                .body(body.clone())
        };
        // 2046: the virus check of the file did not finish in time. Once
        // more after a pause, then say what happened.
        let r = match self.send(upload()).await {
            Err(Error::Isds { code, .. }) if code == AV_TIMEOUT => {
                tokio::time::sleep(std::time::Duration::from_secs(10)).await;
                self.send(upload()).await.map_err(|e| match e {
                    Error::Isds { code, .. } if code == AV_TIMEOUT => Error::Isds {
                        code,
                        text: format!(
                            "ISDS nestihlo zkontrolovat přílohu {name} antivirem. \
                             Zkuste zprávu odeslat znovu později."
                        ),
                    },
                    e => e,
                })?
            }
            r => r?,
        };
        parse_uploaded(&r)
    }

    /// Sends a high-volume message whose files were uploaded by
    /// [`Client::upload_attachment`]; the first is the main document.
    /// `msg.files` is ignored. Returns the new message ID.
    pub async fn create_big_message(
        &self,
        msg: &OutgoingMessage,
        attachments: &[UploadedAttachment],
    ) -> Result<String> {
        if attachments.is_empty() {
            return Err(Error::Isds {
                code: "files".into(),
                text: "zpráva musí mít aspoň jednu přílohu".into(),
            });
        }
        if msg.recipient_box_id.trim().is_empty() || msg.annotation.trim().is_empty() {
            return Err(Error::Isds {
                code: "envelope".into(),
                text: "chybí adresát nebo věc zprávy".into(),
            });
        }
        let r = self
            .call_at(
                &self.vodz_url(),
                "CreateBigMessage",
                &create_big_message_body(msg, attachments),
            )
            .await?;
        r.body
            .child_text("dmID")
            .ok_or_else(|| Error::Xml("odpověď bez dmID".into()))
    }

    /// Uploads `msg.files` and sends them as a high-volume message.
    pub async fn send_big(&self, msg: &OutgoingMessage) -> Result<String> {
        if msg.files.is_empty() {
            return Err(Error::Isds {
                code: "files".into(),
                text: "zpráva musí mít aspoň jednu přílohu".into(),
            });
        }
        let mut atts = Vec::with_capacity(msg.files.len());
        for f in &msg.files {
            atts.push(
                self.upload_attachment(&f.name, &f.mime_type, &f.content)
                    .await?,
            );
        }
        self.create_big_message(msg, &atts).await
    }

    async fn signed_big(&self, op: &str, dm_id: &str) -> Result<Vec<u8>> {
        let inner = format!("<isds:dmID>{}</isds:dmID>", escape(dm_id));
        self.call_vodz_xop(op, &inner).await?.binary("dmSignature")
    }

    /// Downloads a received high-volume message as signed ZFO.
    pub async fn download_big_received(&self, dm_id: &str) -> Result<Vec<u8>> {
        self.signed_big("SignedBigMessageDownload", dm_id).await
    }

    /// Downloads a sent high-volume message as signed ZFO.
    pub async fn download_big_sent(&self, dm_id: &str) -> Result<Vec<u8>> {
        self.signed_big("SignedSentBigMessageDownload", dm_id).await
    }

    /// Downloads one file of a high-volume message; files are numbered from 0.
    pub async fn download_attachment(
        &self,
        dm_id: &str,
        att_num: u32,
    ) -> Result<DownloadedAttachment> {
        let inner = format!(
            "<isds:dmID>{}</isds:dmID><isds:attNum>{att_num}</isds:attNum>",
            escape(dm_id)
        );
        let r = self.call_vodz_xop("DownloadAttachment", &inner).await?;
        let file = r
            .body
            .find("dmFile")
            .ok_or_else(|| Error::Xml("odpověď bez dmFile".into()))?;
        Ok(DownloadedAttachment {
            name: file.attr("dmFileDescr").unwrap_or_default().to_string(),
            mime_type: file.attr("dmMimeType").unwrap_or_default().to_string(),
            content: r.binary("dmEncodedContent")?,
        })
    }

    /// Adds a time stamp to a CAdES message or delivery info ZFO
    /// (`ArchiveISDSDocument`, ws2, SOAP 1.2). Returns the stamped ZFO and
    /// the last day for the next stamp (`nextStampTo`).
    pub async fn archive_document(&self, zfo: &[u8]) -> Result<(Vec<u8>, Option<String>)> {
        let inner = format!(
            "<isds:dmMessage>{}</isds:dmMessage>",
            base64::engine::general_purpose::STANDARD.encode(zfo)
        );
        let req = self
            .http
            .post(format!("{}{ARCH_PATH}", self.vodz_base))
            .header("Content-Type", "application/soap+xml; charset=utf-8")
            .header("Accept", "multipart/related, application/soap+xml")
            .header("SOAPAction", "")
            .body(soap12("ArchiveISDSDocument", &inner));
        let r = self.send(req).await?;
        let doc = r.binary("dmResultDoc")?;
        let next = r
            .body
            .find("nextStampTo")
            .map(|e| e.text.trim().to_string())
            .filter(|d| !d.is_empty());
        Ok((doc, next))
    }

    /// Asks ISDS whether a high-volume message ZFO is authentic.
    pub async fn authenticate_big_message(&self, zfo: &[u8]) -> Result<bool> {
        let inner = format!(
            "<isds:dmMessage>{}</isds:dmMessage>",
            base64::engine::general_purpose::STANDARD.encode(zfo)
        );
        let r = self
            .call_at(&self.vodz_url(), "AuthenticateBigMessage", &inner)
            .await?;
        match r.body.child_text("dmAuthResult").as_deref().map(str::trim) {
            Some("true") | Some("1") => Ok(true),
            Some("false") | Some("0") => Ok(false),
            _ => Err(Error::Xml("odpověď bez dmAuthResult".into())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::isds::multipart;
    use crate::xml;

    fn att(id: &str) -> UploadedAttachment {
        UploadedAttachment {
            id: id.into(),
            hash1: "h1".into(),
            hash1_alg: "SHA-256".into(),
            hash2: "h2".into(),
            hash2_alg: "SHA-512".into(),
        }
    }

    #[test]
    fn builds_create_big_message() {
        let m = OutgoingMessage {
            recipient_box_id: "4h6aibd".into(),
            annotation: "Velká zpráva".into(),
            allow_subst_delivery: true,
            ..Default::default()
        };
        let body = create_big_message_body(&m, &[att("A1"), att("A2")]);
        let doc = xml::parse(format!("<r xmlns:isds=\"x\">{body}</r>").as_bytes()).unwrap();
        let names: Vec<_> = doc.children.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["dmEnvelope", "dmFiles"]);
        let env = doc.find("dmEnvelope").unwrap();
        assert_eq!(env.child_text("dbIDRecipient").as_deref(), Some("4h6aibd"));
        let files: Vec<_> = doc
            .find("dmFiles")
            .unwrap()
            .children_named("dmExtFile")
            .collect();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].attr("dmFileMetaType"), Some("main"));
        assert_eq!(files[1].attr("dmFileMetaType"), Some("enclosure"));
        assert_eq!(files[0].attr("dmAttID"), Some("A1"));
        assert_eq!(files[0].attr("dmAttHash1"), Some("h1"));
        assert_eq!(files[0].attr("dmAttHash1Alg"), Some("SHA-256"));
        assert_eq!(files[0].attr("dmAttHash2"), Some("h2"));
        assert_eq!(files[0].attr("dmAttHash2Alg"), Some("SHA-512"));
        assert!(files[0].children.is_empty());
    }

    #[test]
    fn builds_mtom_upload() {
        let soap = soap12(
            "UploadAttachment",
            &upload_body("Plán \"A\".pdf", "application/pdf"),
        );
        let (ct, body) = mtom_upload(&soap, "Plán \"A\".pdf", "application/pdf", b"\x00BIN");
        assert!(ct.starts_with("multipart/related; type=\"application/xop+xml\""));
        assert!(ct.contains("start=\"<rootpart@soapui.org>\""));
        let (root, parts) = multipart::split(&ct, &body).unwrap();
        assert_eq!(parts, vec![("att_1".to_string(), b"\x00BIN".to_vec())]);

        let doc = xml::parse(&root).unwrap();
        assert_eq!(doc.name, "Envelope");
        let up = doc.find("UploadAttachment").unwrap();
        let file = up.child("dmFile").unwrap();
        assert_eq!(file.attr("dmMimeType"), Some("application/pdf"));
        assert_eq!(file.attr("dmFileDescr"), Some("Plán \"A\".pdf"));
        assert!(file.attr("dmFileMetaType").is_none());
        let inc = file
            .child("dmEncodedContent")
            .unwrap()
            .child("Include")
            .unwrap();
        assert_eq!(inc.attr("href"), Some("cid:att_1"));
        // Header values must not break out of their quotes.
        let text = String::from_utf8_lossy(&body);
        assert!(text.contains("filename=\"Plán _A_.pdf\""));
    }

    #[test]
    fn parses_upload_response() {
        let body = xml::parse(
            br#"<p:UploadAttachmentResponse xmlns:p="http://isds.czechpoint.cz/v20">
              <p:dmAttID>123</p:dmAttID>
              <p:dmAttHash1 AttHashAlg="SHA-1">aaa</p:dmAttHash1>
              <p:dmAttHash2 AttHashAlg="SHA-256">bbb</p:dmAttHash2>
              <p:dmStatus><p:dmStatusCode>0000</p:dmStatusCode></p:dmStatus>
            </p:UploadAttachmentResponse>"#,
        )
        .unwrap();
        let a = parse_uploaded(&Response {
            body,
            parts: Vec::new(),
        })
        .unwrap();
        assert_eq!(
            a,
            UploadedAttachment {
                id: "123".into(),
                hash1: "aaa".into(),
                hash1_alg: "SHA-1".into(),
                hash2: "bbb".into(),
                hash2_alg: "SHA-256".into(),
            }
        );
    }

    #[test]
    fn vodz_urls() {
        let c = Client::new(crate::isds::Credentials {
            username: "u".into(),
            password: "p".into(),
            method: crate::isds::LoginMethod::Password,
            test_env: true,
        })
        .unwrap();
        assert_eq!(c.vodz_url(), "https://ws2.datovka-test.gov.cz/DS/vodz");
        let s = Client::session(reqwest::Client::new(), "https://www.datovka.gov.cz/");
        assert_eq!(s.vodz_url(), "https://www.datovka.gov.cz/apps/DS/vodz");
    }
}
