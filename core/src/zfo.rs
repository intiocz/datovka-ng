//! ZFO files: CMS (PKCS#7) SignedData wrapping the ISDS XML of a message or delivery info.

use base64::Engine;

use crate::ber;
use crate::envelope;
use crate::error::{Error, Result};
use crate::model::{Attachment, Message};
use crate::xml::{self, Element};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZfoKind {
    Message,
    DeliveryInfo,
}

/// Extracts the signed XML payload from a ZFO file.
///
/// The CMS signature itself is not verified here. Unsigned (plain XML) files are
/// returned as they are.
pub fn signed_content(zfo: &[u8]) -> Result<Vec<u8>> {
    if zfo.trim_ascii_start().starts_with(b"<") {
        return Ok(zfo.to_vec());
    }
    ber::signed_data_content(zfo)
}

fn parent_of<'a>(el: &'a Element, child: &str) -> Option<&'a Element> {
    if el.child(child).is_some() {
        return Some(el);
    }
    el.children.iter().find_map(|c| parent_of(c, child))
}

pub fn kind(zfo: &[u8]) -> Result<ZfoKind> {
    let root = xml::parse(&signed_content(zfo)?)?;
    Ok(
        if root.find("dmDelivery").is_some() || root.find("dmEvents").is_some() {
            ZfoKind::DeliveryInfo
        } else {
            ZfoKind::Message
        },
    )
}

/// Parses a message ZFO into envelope and attachments.
pub fn parse_message(zfo: &[u8]) -> Result<Message> {
    let root = xml::parse(&signed_content(zfo)?)?;
    parse_message_xml(&root)
}

pub(crate) fn parse_message_xml(root: &Element) -> Result<Message> {
    let dm = root
        .find("dmDm")
        .ok_or_else(|| Error::Zfo("chybí element dmDm".into()))?;
    let outer = parent_of(root, "dmDm").unwrap_or(dm);
    let envelope = envelope::from_elements(&[dm, outer]);

    let mut attachments = Vec::new();
    if let Some(files) = dm.child("dmFiles") {
        for f in files.children_named("dmFile") {
            let content = if let Some(enc) = f.child("dmEncodedContent") {
                let b64: String = enc.text.split_whitespace().collect();
                base64::engine::general_purpose::STANDARD
                    .decode(b64)
                    .map_err(|e| Error::Zfo(format!("příloha: {e}")))?
            } else {
                Vec::new()
            };
            attachments.push(Attachment {
                file_name: f.attr("dmFileDescr").unwrap_or("priloha").to_string(),
                mime_type: f.attr("dmMimeType").map(str::to_string),
                meta_type: f.attr("dmFileMetaType").map(str::to_string),
                content,
            });
        }
    }
    Ok(Message {
        envelope,
        attachments,
    })
}

/// Delivery events (time as in XML, description) from a delivery info ZFO.
pub fn delivery_events(zfo: &[u8]) -> Result<Vec<(String, String)>> {
    let root = xml::parse(&signed_content(zfo)?)?;
    let Some(events) = root.find("dmEvents") else {
        return Ok(Vec::new());
    };
    Ok(events
        .children_named("dmEvent")
        .map(|e| {
            (
                e.child_text("dmEventTime").unwrap_or_default(),
                e.child_text("dmEventDescr").unwrap_or_default(),
            )
        })
        .collect())
}
