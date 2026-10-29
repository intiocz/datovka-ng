//! Mapping of ISDS XML elements (`dmRecord`, `dmDm`, `dmReturnedMessage`) to [`Envelope`].

use chrono::{DateTime, NaiveDateTime, Utc};

use crate::model::Envelope;
use crate::xml::Element;

pub(crate) fn parse_time(s: &str) -> Option<DateTime<Utc>> {
    if let Ok(t) = DateTime::parse_from_rfc3339(s) {
        return Some(t.with_timezone(&Utc));
    }
    NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f")
        .ok()
        .map(|n| n.and_utc())
}

/// Builds an envelope from the given elements; earlier elements take precedence.
pub(crate) fn from_elements(elements: &[&Element]) -> Envelope {
    let text = |name: &str| elements.iter().find_map(|e| e.child_text(name));
    let attr = |name: &str| {
        elements
            .iter()
            .find_map(|e| e.attr(name).map(str::to_string))
    };
    Envelope {
        dm_id: text("dmID").or_else(|| attr("dmID")).unwrap_or_default(),
        sender_box_id: text("dbIDSender"),
        sender: text("dmSender"),
        sender_address: text("dmSenderAddress"),
        recipient_box_id: text("dbIDRecipient"),
        recipient: text("dmRecipient"),
        recipient_address: text("dmRecipientAddress"),
        annotation: text("dmAnnotation"),
        sender_ref_number: text("dmSenderRefNumber"),
        sender_ident: text("dmSenderIdent"),
        recipient_ref_number: text("dmRecipientRefNumber"),
        recipient_ident: text("dmRecipientIdent"),
        to_hands: text("dmToHands"),
        personal_delivery: text("dmPersonalDelivery").map(|v| v == "true" || v == "1"),
        message_status: text("dmMessageStatus").and_then(|v| v.parse().ok()),
        attachment_size_kb: text("dmAttachmentSize").and_then(|v| v.parse().ok()),
        delivery_time: text("dmDeliveryTime").and_then(|v| parse_time(&v)),
        acceptance_time: text("dmAcceptanceTime").and_then(|v| parse_time(&v)),
        dm_type: text("dmType").or_else(|| attr("dmType")),
        sender_type: text("dmSenderType").and_then(|v| v.parse().ok()),
        ambiguous_recipient: text("dmAmbiguousRecipient").map(|v| v == "true" || v == "1"),
        allow_subst_delivery: text("dmAllowSubstDelivery").map(|v| v == "true" || v == "1"),
        legal_title_law: text("dmLegalTitleLaw"),
        legal_title_year: text("dmLegalTitleYear"),
        legal_title_sect: text("dmLegalTitleSect"),
        legal_title_par: text("dmLegalTitlePar"),
        legal_title_point: text("dmLegalTitlePoint"),
        qtimestamp_b64: text("dmQTimestamp").map(|v| v.split_whitespace().collect()),
        // Attributes of the envelope in ISDS, elements in some older data.
        atts_num: text("attsNum")
            .or_else(|| attr("attsNum"))
            .and_then(|v| v.parse().ok()),
        vodz: text("dmVODZ")
            .or_else(|| attr("dmVODZ"))
            .map(|v| v == "true" || v == "1"),
        spec_mess_flag: attr("specMessFlag").and_then(|v| v.parse().ok()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_suspicious_mark() {
        let doc = crate::xml::parse(
            br#"<dmRecord specMessFlag="1" dmID="42"><dmAnnotation>x</dmAnnotation></dmRecord>"#,
        )
        .unwrap();
        let e = from_elements(&[&doc]);
        assert_eq!((e.dm_id.as_str(), e.spec_mess_flag), ("42", Some(1)));
        let plain = crate::xml::parse(b"<dmRecord dmID=\"43\"/>").unwrap();
        assert_eq!(from_elements(&[&plain]).spec_mess_flag, None);
    }

    #[test]
    fn parses_times() {
        assert!(parse_time("2026-10-27T10:20:30.123+01:00").is_some());
        assert!(parse_time("2026-10-27T10:20:30.123456").is_some());
        assert!(parse_time("bogus").is_none());
    }

    #[test]
    fn high_volume_flag_is_an_attribute() {
        let dm = crate::xml::parse(
            br#"<dmDm dmID="1" dmVODZ="true" attsNum="3"><dmAnnotation>x</dmAnnotation></dmDm>"#,
        )
        .unwrap();
        let e = from_elements(&[&dm]);
        assert_eq!(e.vodz, Some(true));
        assert_eq!(e.atts_num, Some(3));
    }
}
