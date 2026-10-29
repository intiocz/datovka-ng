//! Minimal BER reader for CMS SignedData as produced by ISDS (indefinite lengths,
//! constructed OCTET STRINGs), which strict DER parsers reject.

use crate::error::{Error, Result};

#[derive(Debug, Clone, Copy)]
pub(crate) struct Tlv<'a> {
    pub tag: u8,
    pub constructed: bool,
    /// Content octets (for indefinite length without the end-of-contents marker).
    pub content: &'a [u8],
}

fn err(msg: &str) -> Error {
    Error::Zfo(msg.to_string())
}

/// Reads one TLV from `data`, returns it and the total number of bytes consumed.
pub(crate) fn read(data: &[u8]) -> Result<(Tlv<'_>, usize)> {
    let &first = data.first().ok_or_else(|| err("neočekávaný konec dat"))?;
    if first & 0x1f == 0x1f {
        return Err(err("vícebajtové tagy nejsou podporovány"));
    }
    let constructed = first & 0x20 != 0;
    let &len0 = data.get(1).ok_or_else(|| err("chybí délka"))?;
    let mut pos = 2;
    if len0 == 0x80 {
        if !constructed {
            return Err(err("neurčitá délka u primitivního typu"));
        }
        // Indefinite: walk children until end-of-contents (00 00).
        let start = pos;
        loop {
            match data.get(pos..pos + 2) {
                Some([0, 0]) => break,
                Some(_) => pos += read(&data[pos..])?.1,
                None => return Err(err("chybí konec neurčité délky")),
            }
        }
        let tlv = Tlv {
            tag: first,
            constructed,
            content: &data[start..pos],
        };
        return Ok((tlv, pos + 2));
    }
    let len = if len0 & 0x80 == 0 {
        len0 as usize
    } else {
        let n = (len0 & 0x7f) as usize;
        if n > 8 {
            return Err(err("příliš dlouhá délka"));
        }
        let bytes = data.get(pos..pos + n).ok_or_else(|| err("chybí délka"))?;
        pos += n;
        bytes.iter().fold(0usize, |acc, b| (acc << 8) | *b as usize)
    };
    let content = data
        .get(pos..pos + len)
        .ok_or_else(|| err("obsah přesahuje data"))?;
    Ok((
        Tlv {
            tag: first,
            constructed,
            content,
        },
        pos + len,
    ))
}

/// All child TLVs of a constructed value.
pub(crate) fn children(content: &[u8]) -> Result<Vec<Tlv<'_>>> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < content.len() {
        let (t, n) = read(&content[pos..])?;
        out.push(t);
        pos += n;
    }
    Ok(out)
}

/// All child TLVs of a constructed value together with their complete encodings
/// (tag, length and content), e.g. for handing DER sub-structures to a DER parser.
pub(crate) fn children_raw(content: &[u8]) -> Result<Vec<(Tlv<'_>, &[u8])>> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < content.len() {
        let (t, n) = read(&content[pos..])?;
        out.push((t, &content[pos..pos + n]));
        pos += n;
    }
    Ok(out)
}

/// Value of an OCTET STRING, concatenating segments of the constructed form.
pub(crate) fn octets(t: &Tlv) -> Result<Vec<u8>> {
    if t.tag & 0x1f != 0x04 {
        return Err(err("očekáván OCTET STRING"));
    }
    if !t.constructed {
        return Ok(t.content.to_vec());
    }
    let mut out = Vec::new();
    for c in children(t.content)? {
        out.extend(octets(&c)?);
    }
    Ok(out)
}

/// Extracts `encapContentInfo.eContent` from a CMS ContentInfo with SignedData.
pub(crate) fn signed_data_content(der: &[u8]) -> Result<Vec<u8>> {
    let (ci, _) = read(der)?;
    // ContentInfo ::= SEQUENCE { contentType OID, content [0] EXPLICIT ANY }
    let ci = children(ci.content)?;
    let explicit = ci.get(1).ok_or_else(|| err("ContentInfo bez obsahu"))?;
    let (sd, _) = read(explicit.content)?;
    // SignedData ::= SEQUENCE { version, digestAlgorithms, encapContentInfo, ... }
    let sd = children(sd.content)?;
    let eci = sd
        .get(2)
        .ok_or_else(|| err("SignedData bez encapContentInfo"))?;
    let eci = children(eci.content)?;
    let econtent = eci.get(1).ok_or_else(|| err("chybí podepsaný obsah"))?;
    let (inner, _) = read(econtent.content)?;
    octets(&inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_indefinite_and_constructed_octets() {
        // SEQUENCE (indef) { OCTET STRING constructed (indef) { "ab", "c" } }
        let data = [
            0x30, 0x80, 0x24, 0x80, 0x04, 0x02, b'a', b'b', 0x04, 0x01, b'c', 0, 0, 0, 0,
        ];
        let (seq, n) = read(&data).unwrap();
        assert_eq!(n, data.len());
        let kids = children(seq.content).unwrap();
        assert_eq!(octets(&kids[0]).unwrap(), b"abc");
    }
}
