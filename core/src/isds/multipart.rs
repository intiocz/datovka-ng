//! Minimal `multipart/related` (MTOM/XOP) splitter for ISDS responses.

use crate::error::{Error, Result};

fn param<'a>(content_type: &'a str, name: &str) -> Option<&'a str> {
    content_type.split(';').find_map(|p| {
        let (k, v) = p.trim().split_once('=')?;
        k.eq_ignore_ascii_case(name)
            .then(|| v.trim().trim_matches('"'))
    })
}

fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    hay.get(from..)?
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| p + from)
}

/// MTOM/XOP parts as (Content-ID, data).
pub(super) type Parts = Vec<(String, Vec<u8>)>;

/// Returns the root (SOAP) part and the remaining parts.
pub(super) fn split(content_type: &str, body: &[u8]) -> Result<(Vec<u8>, Parts)> {
    let boundary = param(content_type, "boundary")
        .ok_or_else(|| Error::Xml("multipart bez boundary".into()))?;
    let start = param(content_type, "start").map(|s| s.trim_matches(['<', '>']).to_string());
    let delim = format!("--{boundary}").into_bytes();

    let mut parts: Parts = Vec::new();
    let mut pos = find(body, &delim, 0).ok_or_else(|| Error::Xml("multipart bez částí".into()))?;
    loop {
        pos += delim.len();
        if body.get(pos..pos + 2) == Some(b"--") {
            break;
        }
        let Some(next) = find(body, &delim, pos) else {
            break;
        };
        let part = &body[pos..next];
        let part = part.strip_prefix(b"\r\n").unwrap_or(part);
        let part = part.strip_suffix(b"\r\n").unwrap_or(part);
        let header_end = find(part, b"\r\n\r\n", 0).unwrap_or(0);
        let headers = String::from_utf8_lossy(&part[..header_end]);
        let data = part.get(header_end + 4..).unwrap_or_default().to_vec();
        let cid = headers
            .lines()
            .find_map(|l| {
                let (k, v) = l.split_once(':')?;
                k.trim()
                    .eq_ignore_ascii_case("content-id")
                    .then(|| v.trim().trim_matches(['<', '>']).to_string())
            })
            .unwrap_or_default();
        parts.push((cid, data));
        pos = next;
    }

    let root_idx = start
        .and_then(|s| parts.iter().position(|(id, _)| *id == s))
        .unwrap_or(0);
    if parts.is_empty() {
        return Err(Error::Xml("multipart bez částí".into()));
    }
    let (_, root) = parts.remove(root_idx);
    Ok((root, parts))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_mtom() {
        let body = b"--b1\r\nContent-ID: <root>\r\nContent-Type: application/xop+xml\r\n\r\n<x/>\r\n--b1\r\nContent-ID: <att@1>\r\n\r\n\x00\x01BIN\r\n--b1--\r\n";
        let (root, parts) =
            split(r#"multipart/related; boundary="b1"; start="<root>""#, body).unwrap();
        assert_eq!(root, b"<x/>");
        assert_eq!(parts, vec![("att@1".to_string(), b"\x00\x01BIN".to_vec())]);
    }
}
