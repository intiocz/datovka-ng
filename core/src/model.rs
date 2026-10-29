use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Whether a message was received into or sent from the data box.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Received,
    Sent,
}

impl Direction {
    pub fn as_str(self) -> &'static str {
        match self {
            Direction::Received => "received",
            Direction::Sent => "sent",
        }
    }
}

/// Message envelope as returned by ISDS listing operations and contained in ZFO.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    pub dm_id: String,
    pub sender_box_id: Option<String>,
    pub sender: Option<String>,
    pub sender_address: Option<String>,
    pub recipient_box_id: Option<String>,
    pub recipient: Option<String>,
    pub recipient_address: Option<String>,
    pub annotation: Option<String>,
    pub sender_ref_number: Option<String>,
    pub sender_ident: Option<String>,
    pub recipient_ref_number: Option<String>,
    pub recipient_ident: Option<String>,
    pub to_hands: Option<String>,
    pub personal_delivery: Option<bool>,
    pub message_status: Option<u8>,
    pub attachment_size_kb: Option<u64>,
    pub delivery_time: Option<DateTime<Utc>>,
    pub acceptance_time: Option<DateTime<Utc>>,
    pub dm_type: Option<String>,
    pub sender_type: Option<i64>,
    pub ambiguous_recipient: Option<bool>,
    pub allow_subst_delivery: Option<bool>,
    pub legal_title_law: Option<String>,
    pub legal_title_year: Option<String>,
    pub legal_title_sect: Option<String>,
    pub legal_title_par: Option<String>,
    pub legal_title_point: Option<String>,
    /// Qualified timestamp, base64 as found in ISDS XML.
    pub qtimestamp_b64: Option<String>,
    pub atts_num: Option<i64>,
    pub vodz: Option<bool>,
}

impl Envelope {
    /// Human readable meaning of `dmMessageStatus` (ISDS codes 1–10).
    pub fn status_text(&self) -> &'static str {
        match self.message_status {
            Some(1) => "podána",
            Some(2) => "opatřena časovým razítkem",
            Some(3) => "neprošla antivirovou kontrolou",
            Some(4) => "dodána do schránky",
            Some(5) => "doručena fikcí",
            Some(6) => "doručena přihlášením",
            Some(7) => "přečtena",
            Some(8) => "nedoručitelná",
            Some(9) => "obsah smazán",
            Some(10) => "v datovém trezoru",
            _ => "neznámý stav",
        }
    }
}

/// A file attached to a message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Attachment {
    pub file_name: String,
    pub mime_type: Option<String>,
    /// `main`, `enclosure`, `signature` or `meta`.
    pub meta_type: Option<String>,
    #[serde(skip)]
    pub content: Vec<u8>,
}

/// Fully downloaded message: envelope plus attachments.
#[derive(Debug, Clone, PartialEq)]
pub struct Message {
    pub envelope: Envelope,
    pub attachments: Vec<Attachment>,
}

/// Information about the data box the user is logged into.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct OwnerInfo {
    pub box_id: String,
    pub box_type: Option<String>,
    pub name: Option<String>,
    pub ic: Option<String>,
}
