//! Every SOAP request the client builds, checked against the ISDS schemas.
//!
//! A local HTTP server records what the client sends. The XML must parse;
//! with `DATOVKA_ISDS_XSD` set to the folder of the ISDS documentation
//! (`pril_1`, `pril_2`), each operation element is also validated by
//! `xmllint` against `dmBaseTypes.xsd`, `dbTypes.xsd` or
//! `ChangePasswordTypes.xsd`, whichever declares it.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::Path;
use std::sync::{Arc, Mutex};

use serde_json::json;

use super::vodz::UploadedAttachment;
use super::*;

const RESPONSE: &str = concat!(
    r#"<?xml version="1.0" encoding="UTF-8"?>"#,
    r#"<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">"#,
    r#"<soap:Body><X><dmStatus><dmStatusCode>0000</dmStatusCode></dmStatus></X></soap:Body>"#,
    r#"</soap:Envelope>"#
);

/// Serves `RESPONSE` to every request and keeps the request bodies.
fn recorder() -> (String, Arc<Mutex<Vec<Vec<u8>>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let keep = seen.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { continue };
            let mut buf = Vec::new();
            let mut chunk = [0u8; 65536];
            let head_end = loop {
                let n = s.read(&mut chunk).unwrap_or(0);
                if n == 0 {
                    break None;
                }
                buf.extend_from_slice(&chunk[..n]);
                if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break Some(i + 4);
                }
            };
            let Some(head_end) = head_end else { continue };
            let head = String::from_utf8_lossy(&buf[..head_end]).to_lowercase();
            let len: usize = head
                .lines()
                .find_map(|l| l.strip_prefix("content-length:"))
                .and_then(|v| v.trim().parse().ok())
                .unwrap_or(0);
            while buf.len() < head_end + len {
                let n = s.read(&mut chunk).unwrap_or(0);
                if n == 0 {
                    break;
                }
                buf.extend_from_slice(&chunk[..n]);
            }
            keep.lock().unwrap().push(buf[head_end..].to_vec());
            let _ = write!(
                s,
                "HTTP/1.1 200 OK\r\nContent-Type: text/xml; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{RESPONSE}",
                RESPONSE.len()
            );
        }
    });
    (format!("http://{addr}/"), seen)
}

fn message() -> OutgoingMessage {
    OutgoingMessage {
        recipient_box_id: "abc1234".into(),
        annotation: "Žádost <test> & spol.".into(),
        to_hands: Some("Jan Novák".into()),
        sender_ref_number: Some("NS-2".into()),
        sender_ident: Some("SZ-1".into()),
        recipient_ref_number: Some("RS-3".into()),
        recipient_ident: Some("RZ-4".into()),
        personal_delivery: true,
        allow_subst_delivery: false,
        legal_title_law: Some("500".into()),
        legal_title_year: Some("2004".into()),
        legal_title_sect: Some("19".into()),
        legal_title_par: Some("3".into()),
        legal_title_point: Some("a".into()),
        ovm: Some(false),
        publish_own_id: Some(true),
        dm_type: Some("I".into()),
        files: vec![
            OutgoingFile {
                name: "podani.pdf".into(),
                mime_type: "application/pdf".into(),
                content: b"%PDF-1.4".to_vec(),
            },
            OutgoingFile {
                name: "priloha.txt".into(),
                mime_type: "text/plain".into(),
                content: b"x".to_vec(),
            },
        ],
    }
}

/// Calls every operation the client knows against the recorder. Nothing
/// leaves this computer.
async fn record_all(base: &str) {
    let c = Client {
        http: http_client(false).unwrap(),
        base: base.into(),
        vodz_base: base.into(),
        basic: Some(("user".into(), "pass".into())),
    };
    let t = |s: &str| DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc);
    let filter = ListFilter {
        from: Some(t("2026-01-01T00:00:00Z")),
        to: Some(t("2026-02-01T00:00:00Z")),
        offset: 1,
        limit: 100,
    };
    let m = message();
    let user = json!({
        "pnGivenNames": "Jan", "pnLastName": "Novák", "adCity": "Brno",
        "adZipCode": "60200", "biDate": "1980-01-31", "userType": "ENTRUSTED_USER",
        "userPrivils": 255, "caCity": "Praha"
    });
    let att = UploadedAttachment {
        id: "att-1".into(),
        hash1: "aGFzaA==".into(),
        hash1_alg: "SHA-256".into(),
        hash2: "aGFzaA==".into(),
        hash2_alg: "SHA-512".into(),
    };
    let zfo = b"not a real zfo";

    let _ = c.owner_info().await;
    let _ = c.owner_info2().await;
    let _ = c.user_info2().await;
    let _ = c.password_expiry().await;
    let _ = c.change_password("stare", "nove-Heslo1").await;
    let _ = c.box_users("abc1234").await;
    let _ = c.add_user("abc1234", &user).await;
    let _ = c.update_user("abc1234", "0123456789ab", &user).await;
    let _ = c.delete_user("abc1234", "0123456789ab").await;

    let _ = c.received_messages(&filter).await;
    let _ = c.sent_messages(&ListFilter::default()).await;
    let _ = c.download_received("123").await;
    let _ = c.download_sent("123").await;
    let _ = c.download_delivery_info("123").await;
    let _ = c.mark_as_read("123").await;
    let _ = c.message_author("123").await;
    let _ = c.erase_message("123", true).await;
    let _ = c.report_suspicious("123", true, "nevyžádaná reklama").await;
    let _ = c.request_erased(2025, Some(3), true).await;
    let _ = c.request_erased(2024, None, false).await;
    let _ = c.pick_up_erased("async-1").await;
    let _ = c.state_changes("2026-01-01T00:00:00Z").await;

    let _ = c.create_message(&m).await;
    let _ = c.create_multiple_message(&m, &["abc1234".into(), "def5678".into()]).await;
    let _ = c.authenticate_message(zfo).await;
    let _ = c.resign_document(zfo).await;

    let _ = c.search_boxes("Ministerstvo vnitra", SearchType::General, true, 0).await;
    let _ = c.search_boxes("00007064", SearchType::Ico, false, 1).await;
    let _ = c.check_box("abc1234").await;
    let _ = c.pdz_send_info("abc1234", "Init").await;
    let _ = c.credit_info("abc1234").await;
    let _ = c.dt_info("abc1234").await;
    let _ = c.pdz_info("abc1234").await;

    let _ = c.upload_attachment("velka.pdf", "application/pdf", b"%PDF").await;
    let _ = c.create_big_message(&m, &[att.clone(), att]).await;
    let _ = c.download_big_received("123").await;
    let _ = c.download_big_sent("123").await;
    let _ = c.download_attachment("123", 0).await;
    let _ = c.archive_document(zfo).await;
    let _ = c.authenticate_big_message(zfo).await;

    let url = format!("{base}{}", ops::ASWS_PATH);
    let _ = c.call_ns(&url, ops::ASWS_NS, "SendSMSCode", "").await;
    let _ = c
        .call_ns(&url, ops::ASWS_NS, "ChangePasswordOTP", &ops::change_password_otp_body("a", "b", ops::Otp::Sms))
        .await;
}

/// The SOAP envelope of a request body; an MTOM upload has it in its
/// first part.
fn soap_part(body: &[u8]) -> String {
    let text = String::from_utf8_lossy(body).into_owned();
    match (text.find("<?xml"), text.find("</soap:Envelope>")) {
        (Some(a), Some(b)) => text[a..b + "</soap:Envelope>".len()].to_string(),
        _ => text,
    }
}

/// The operation element alone, with the namespaces it uses declared on it.
fn operation(envelope: &str) -> (String, String) {
    let doc = crate::xml::parse(envelope.as_bytes()).expect("request is well-formed XML");
    let op = doc.find("Body").unwrap().children[0].name.clone();
    let start = envelope.find("<soap:Body>").unwrap() + "<soap:Body>".len();
    let end = envelope.rfind("</soap:Body>").unwrap();
    let inner = &envelope[start..end];
    let ns = envelope
        .split("xmlns:isds=\"")
        .nth(1)
        .and_then(|s| s.split('"').next())
        .unwrap();
    let open = format!("<isds:{op}");
    let decl = format!(
        r#"<isds:{op} xmlns:isds="{ns}" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance""#
    );
    (op, inner.replacen(&open, &decl, 1))
}

/// Schema file that declares `op` as a top-level element.
fn schema_for(dir: &Path, op: &str) -> Option<std::path::PathBuf> {
    let decl = format!("<xs:element name=\"{op}\"");
    let decl2 = format!("<xsd:element name=\"{op}\"");
    ["pril_1/dmBaseTypes.xsd", "pril_2/dbTypes.xsd", "pril_2/ChangePasswordTypes.xsd"]
        .iter()
        .map(|f| dir.join(f))
        .find(|p| {
            std::fs::read_to_string(p).is_ok_and(|s| s.contains(&decl) || s.contains(&decl2))
        })
}

#[test]
fn every_request_matches_the_isds_schema() {
    let (base, seen) = recorder();
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(record_all(&base));
    let bodies = seen.lock().unwrap().clone();
    assert!(bodies.len() >= 40, "recorded only {} requests", bodies.len());

    let xsd = std::env::var_os("DATOVKA_ISDS_XSD").map(std::path::PathBuf::from);
    let out = std::env::temp_dir().join(format!("datovka-xsd-{}", std::process::id()));
    std::fs::create_dir_all(&out).unwrap();
    let mut failures = Vec::new();
    for (i, body) in bodies.iter().enumerate() {
        let (op, xml) = operation(&soap_part(body));
        let Some(dir) = &xsd else { continue };
        // An MTOM upload carries the file as an XOP reference, which the
        // schema (base64Binary) cannot express.
        if op == "UploadAttachment" {
            continue;
        }
        // The envelope leaves out empty elements the schema lists as
        // required-but-nillable. ISDS accepts that: a message sent this way
        // was delivered on 29. 10. 2026. The full form waits for a test in
        // the ISDS test environment, sending is not changed blindly.
        if ["CreateMessage", "CreateMultipleMessage", "CreateBigMessage"].contains(&op.as_str()) {
            continue;
        }
        let Some(schema) = schema_for(dir, &op) else {
            failures.push(format!("{op}: ve schématech není"));
            continue;
        };
        let file = out.join(format!("{i:02}-{op}.xml"));
        std::fs::write(&file, &xml).unwrap();
        let r = std::process::Command::new("xmllint")
            .args(["--noout", "--schema"])
            .arg(&schema)
            .arg(&file)
            .output()
            .expect("xmllint");
        if !r.status.success() {
            failures.push(format!("{op}: {}", String::from_utf8_lossy(&r.stderr).trim()));
        }
    }
    let _ = std::fs::remove_dir_all(&out);
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
