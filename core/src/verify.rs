//! Local verification of a ZFO's CMS signature and its time stamps, like the
//! signature detail dialog of the original Datovka.
//!
//! What is checked:
//! - the CMS signature of the ZFO (signed attributes verified with the signer
//!   certificate's RSA key, `messageDigest` equal to the digest of the signed XML),
//! - `dmHash` in the XML against the hash of the raw `dmDm` element (this is how
//!   ISDS / libisds compute it),
//! - the qualified time stamp `dmQTimestamp` (RFC 3161 token): its own CMS
//!   signature, and that its `messageImprint` equals the `dmHash` value,
//! - the signature time stamp in the CMS unsigned attributes (if present): its
//!   signature and that its imprint is the hash of the CMS signature value,
//! - certificate chains against the bundled PostSignum certificates (`core/certs`),
//!   each certificate valid at the signing / time-stamping time.
//!
//! Revocation (CRL, OCSP) is not checked.

use std::sync::OnceLock;

use base64::Engine;
use chrono::{DateTime, NaiveDateTime, Utc};
use der::{Decode, Encode};
use rsa::pkcs8::DecodePublicKey;
use rsa::{Pkcs1v15Sign, Pss, RsaPublicKey};
use serde::Serialize;
use sha2::Digest as _;
use x509_cert::ext::pkix::BasicConstraints;
use x509_cert::name::Name;
use x509_cert::spki::ObjectIdentifier;
use x509_cert::Certificate;

use crate::ber::{self, Tlv};
use crate::error::{Error, Result};
use crate::xml;

const OID_SIGNED_DATA: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.7.2");
const OID_TST_INFO: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.9.16.1.4");
const OID_MESSAGE_DIGEST: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.9.4");
const OID_SIGNING_TIME: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.9.5");
const OID_TST_ATTR: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.9.16.2.14");
const OID_CN: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.4.3");
const OID_O: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.4.10");
const OID_SKI: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.29.14");
const OID_BASIC_CONSTRAINTS: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.29.19");
const OID_EXT_KEY_USAGE: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.29.37");
const OID_KP_TIME_STAMPING: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.3.6.1.5.5.7.3.8");
const OID_RSA_PSS: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.1.10");

/// Bundled trusted certificates (copied from the original Datovka's `trusted_certs`).
const BUNDLED_PEMS: &[&str] = &[
    include_str!("../certs/postsignum_qca_root.pem"),
    include_str!("../certs/postsignum_qca_sub.pem"),
    include_str!("../certs/postsignum_qca2_root.pem"),
    include_str!("../certs/postsignum_qca2_sub.pem"),
    include_str!("../certs/postsignum_qca3_sub.pem"),
    include_str!("../certs/postsignum_qca3_sub-tsa.pem"),
    include_str!("../certs/postsignum_qca4_root.pem"),
    include_str!("../certs/postsignum_qca4_sub.pem"),
    include_str!("../certs/postsignum_qca5_sub.pem"),
];

/// Subject or issuer of a certificate.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CertName {
    pub common_name: Option<String>,
    pub organization: Option<String>,
    /// Full distinguished name (RFC 4514).
    pub dn: String,
}

/// `dmHash` from the XML compared with the hash of the raw `dmDm` element.
#[derive(Debug, Clone, Serialize)]
pub struct DmHashReport {
    pub algorithm: String,
    /// Base64 value as stated in the XML.
    pub value: String,
    /// `None` for a delivery info, which lacks the attachments the hash covers.
    pub matches_content: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TimestampReport {
    pub gen_time: Option<DateTime<Utc>>,
    /// Hash algorithm of the message imprint.
    pub hash_algorithm: Option<String>,
    /// The imprint covers what it should (`dmHash` value for the envelope time
    /// stamp, the CMS signature value for the signature time stamp).
    pub imprint_matches: bool,
    /// The time stamp token's own CMS signature verifies.
    pub signature_valid: bool,
    pub serial_number: Option<String>,
    pub tsa: Option<CertName>,
    pub tsa_issuer: Option<CertName>,
    pub tsa_cert_not_before: Option<DateTime<Utc>>,
    pub tsa_cert_not_after: Option<DateTime<Utc>>,
    /// TSA certificate chains to a bundled root, all certificates valid at
    /// `gen_time`, and the certificate is meant for time stamping.
    pub chain_trusted: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SignatureReport {
    /// CMS signature over the signed attributes verifies with the signer
    /// certificate and `messageDigest` equals the digest of the signed content.
    pub signature_valid: bool,
    pub signer: Option<CertName>,
    pub issuer: Option<CertName>,
    pub cert_serial: Option<String>,
    pub cert_not_before: Option<DateTime<Utc>>,
    pub cert_not_after: Option<DateTime<Utc>>,
    /// Signer certificate valid at the signing time (or now when unknown).
    pub cert_valid_at_signing: Option<bool>,
    pub signing_time: Option<DateTime<Utc>>,
    pub digest_algorithm: Option<String>,
    pub signature_algorithm: Option<String>,
    /// Chain to a bundled PostSignum root verified, all certificates valid at
    /// the signing time. `None` when there is no signer certificate.
    pub chain_trusted: Option<bool>,
    /// Common names from the signer certificate up to the root.
    pub chain: Vec<String>,
    pub dm_hash: Option<DmHashReport>,
    /// Qualified time stamp from the XML element `dmQTimestamp`.
    pub timestamp: Option<TimestampReport>,
    /// Time stamp over the CMS signature (unsigned attribute), if any.
    pub signature_timestamp: Option<TimestampReport>,
    /// Human-readable reasons for failed checks.
    pub problems: Vec<String>,
}

fn err(msg: &str) -> Error {
    Error::Zfo(msg.to_string())
}

// ---------------------------------------------------------------- digests

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DigestAlg {
    Sha1,
    Sha224,
    Sha256,
    Sha384,
    Sha512,
}

impl DigestAlg {
    fn from_oid(oid: &ObjectIdentifier) -> Option<Self> {
        Some(match oid.to_string().as_str() {
            "1.3.14.3.2.26" => Self::Sha1,
            "2.16.840.1.101.3.4.2.4" => Self::Sha224,
            "2.16.840.1.101.3.4.2.1" => Self::Sha256,
            "2.16.840.1.101.3.4.2.2" => Self::Sha384,
            "2.16.840.1.101.3.4.2.3" => Self::Sha512,
            _ => return None,
        })
    }

    /// Digest of an RSA PKCS#1 v1.5 signature algorithm; `rsaEncryption` takes
    /// the digest given separately.
    fn from_sig_oid(oid: &ObjectIdentifier, plain_rsa: Option<Self>) -> Option<Self> {
        Some(match oid.to_string().as_str() {
            "1.2.840.113549.1.1.1" => return plain_rsa,
            "1.2.840.113549.1.1.5" => Self::Sha1,
            "1.2.840.113549.1.1.14" => Self::Sha224,
            "1.2.840.113549.1.1.11" => Self::Sha256,
            "1.2.840.113549.1.1.12" => Self::Sha384,
            "1.2.840.113549.1.1.13" => Self::Sha512,
            _ => return None,
        })
    }

    fn from_xml_name(name: &str) -> Option<Self> {
        Some(match name.to_ascii_uppercase().replace('-', "").as_str() {
            "SHA1" => Self::Sha1,
            "SHA224" => Self::Sha224,
            "SHA256" => Self::Sha256,
            "SHA384" => Self::Sha384,
            "SHA512" => Self::Sha512,
            _ => return None,
        })
    }

    fn name(self) -> &'static str {
        match self {
            Self::Sha1 => "SHA-1",
            Self::Sha224 => "SHA-224",
            Self::Sha256 => "SHA-256",
            Self::Sha384 => "SHA-384",
            Self::Sha512 => "SHA-512",
        }
    }

    fn hash(self, data: &[u8]) -> Vec<u8> {
        match self {
            Self::Sha1 => sha1::Sha1::digest(data).to_vec(),
            Self::Sha224 => sha2::Sha224::digest(data).to_vec(),
            Self::Sha256 => sha2::Sha256::digest(data).to_vec(),
            Self::Sha384 => sha2::Sha384::digest(data).to_vec(),
            Self::Sha512 => sha2::Sha512::digest(data).to_vec(),
        }
    }

    fn pkcs1v15(self) -> Pkcs1v15Sign {
        match self {
            Self::Sha1 => Pkcs1v15Sign::new::<sha1::Sha1>(),
            Self::Sha224 => Pkcs1v15Sign::new::<sha2::Sha224>(),
            Self::Sha256 => Pkcs1v15Sign::new::<sha2::Sha256>(),
            Self::Sha384 => Pkcs1v15Sign::new::<sha2::Sha384>(),
            Self::Sha512 => Pkcs1v15Sign::new::<sha2::Sha512>(),
        }
    }

    fn pss(self, salt: usize) -> Pss {
        match self {
            Self::Sha1 => Pss::new_with_salt::<sha1::Sha1>(salt),
            Self::Sha224 => Pss::new_with_salt::<sha2::Sha224>(salt),
            Self::Sha256 => Pss::new_with_salt::<sha2::Sha256>(salt),
            Self::Sha384 => Pss::new_with_salt::<sha2::Sha384>(salt),
            Self::Sha512 => Pss::new_with_salt::<sha2::Sha512>(salt),
        }
    }
}

/// Supported RSA signature schemes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SigScheme {
    Pkcs1(DigestAlg),
    Pss { digest: DigestAlg, salt: usize },
}

impl SigScheme {
    /// From a complete encoded AlgorithmIdentifier; `rsaEncryption` takes the
    /// digest given separately.
    fn from_alg_id(raw: &[u8], plain_rsa: Option<DigestAlg>) -> Option<Self> {
        let (seq, _) = ber::read(raw).ok()?;
        let kids = ber::children(seq.content).ok()?;
        let oid = oid_of(kids.first()?)?;
        if oid != OID_RSA_PSS {
            return DigestAlg::from_sig_oid(&oid, plain_rsa).map(Self::Pkcs1);
        }
        // RSASSA-PSS-params with defaults SHA-1, MGF1(SHA-1), salt 20.
        let (mut digest, mut mgf_digest, mut salt) = (DigestAlg::Sha1, DigestAlg::Sha1, 20);
        let params = kids.get(1).filter(|t| t.tag == 0x30);
        for p in params
            .and_then(|t| ber::children(t.content).ok())
            .unwrap_or_default()
        {
            let (inner, _) = ber::read(p.content).ok()?;
            match p.tag {
                0xa0 => digest = alg_oid(&inner).as_ref().and_then(DigestAlg::from_oid)?,
                0xa1 => {
                    // MaskGenAlgorithm { mgf1, AlgorithmIdentifier of the hash }
                    let mgf = ber::children(inner.content).ok()?;
                    mgf_digest = alg_oid(mgf.get(1)?)
                        .as_ref()
                        .and_then(DigestAlg::from_oid)?;
                }
                0xa2 => {
                    salt = inner
                        .content
                        .iter()
                        .fold(0usize, |acc, b| (acc << 8) | *b as usize)
                }
                _ => {}
            }
        }
        // The rsa crate uses the same hash for MGF1.
        (digest == mgf_digest).then_some(Self::Pss { digest, salt })
    }

    fn name(self) -> String {
        match self {
            Self::Pkcs1(d) => format!("RSA PKCS#1 v1.5 ({})", d.name()),
            Self::Pss { digest, .. } => format!("RSA-PSS ({})", digest.name()),
        }
    }
}

// ---------------------------------------------------------------- certificates

struct Cert {
    raw: Vec<u8>,
    tbs: Vec<u8>,
    x: Certificate,
}

impl Cert {
    fn parse(raw: &[u8]) -> Result<Self> {
        let x = Certificate::from_der(raw).map_err(|e| Error::Zfo(format!("certifikát: {e}")))?;
        let (seq, _) = ber::read(raw)?;
        let tbs = ber::children_raw(seq.content)?
            .first()
            .ok_or_else(|| err("certifikát bez TBS"))?
            .1
            .to_vec();
        Ok(Self {
            raw: raw.to_vec(),
            tbs,
            x,
        })
    }

    fn subject(&self) -> &Name {
        &self.x.tbs_certificate.subject
    }

    fn issuer(&self) -> &Name {
        &self.x.tbs_certificate.issuer
    }

    fn extension(&self, oid: ObjectIdentifier) -> Option<&[u8]> {
        self.x
            .tbs_certificate
            .extensions
            .as_ref()?
            .iter()
            .find(|e| e.extn_id == oid)
            .map(|e| e.extn_value.as_bytes())
    }

    fn subject_key_id(&self) -> Option<Vec<u8>> {
        let (t, _) = ber::read(self.extension(OID_SKI)?).ok()?;
        ber::octets(&t).ok()
    }

    fn is_ca(&self) -> bool {
        self.extension(OID_BASIC_CONSTRAINTS)
            .and_then(|v| BasicConstraints::from_der(v).ok())
            .is_some_and(|bc| bc.ca)
    }

    fn has_time_stamping_eku(&self) -> bool {
        let Some(v) = self.extension(OID_EXT_KEY_USAGE) else {
            return false;
        };
        let Ok((seq, _)) = ber::read(v) else {
            return false;
        };
        ber::children(seq.content)
            .unwrap_or_default()
            .iter()
            .any(|t| oid_of(t) == Some(OID_KP_TIME_STAMPING))
    }

    fn not_before(&self) -> Option<DateTime<Utc>> {
        unix(
            self.x
                .tbs_certificate
                .validity
                .not_before
                .to_unix_duration(),
        )
    }

    fn not_after(&self) -> Option<DateTime<Utc>> {
        unix(self.x.tbs_certificate.validity.not_after.to_unix_duration())
    }

    fn valid_at(&self, t: DateTime<Utc>) -> bool {
        matches!((self.not_before(), self.not_after()), (Some(a), Some(b)) if a <= t && t <= b)
    }

    fn serial_hex(&self) -> String {
        hex(self.x.tbs_certificate.serial_number.as_bytes())
    }

    fn name(&self) -> CertName {
        cert_name(self.subject())
    }

    /// Verifies `signature` over `data` with this certificate's RSA key.
    fn rsa_verify(&self, scheme: SigScheme, data: &[u8], signature: &[u8]) -> bool {
        let Ok(spki) = self.x.tbs_certificate.subject_public_key_info.to_der() else {
            return false;
        };
        let Ok(key) = RsaPublicKey::from_public_key_der(&spki) else {
            return false;
        };
        match scheme {
            SigScheme::Pkcs1(d) => key.verify(d.pkcs1v15(), &d.hash(data), signature),
            SigScheme::Pss { digest, salt } => {
                key.verify(digest.pss(salt), &digest.hash(data), signature)
            }
        }
        .is_ok()
    }

    /// Whether this certificate's signature was made by `issuer`'s key.
    fn signed_by(&self, issuer: &Cert) -> bool {
        if self.issuer() != issuer.subject() {
            return false;
        }
        let Some(digest) = self
            .x
            .signature_algorithm
            .to_der()
            .ok()
            .and_then(|raw| SigScheme::from_alg_id(&raw, None))
        else {
            return false;
        };
        let Some(sig) = self.x.signature.as_bytes() else {
            return false;
        };
        issuer.rsa_verify(digest, &self.tbs, sig)
    }
}

fn unix(d: std::time::Duration) -> Option<DateTime<Utc>> {
    DateTime::from_timestamp(d.as_secs() as i64, 0)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02X}")).collect()
}

fn cert_name(name: &Name) -> CertName {
    let attr = |oid: ObjectIdentifier| {
        name.0.iter().flat_map(|rdn| rdn.0.iter()).find_map(|atv| {
            (atv.oid == oid).then(|| String::from_utf8_lossy(atv.value.value()).into_owned())
        })
    };
    CertName {
        common_name: attr(OID_CN),
        organization: attr(OID_O),
        dn: name.to_string(),
    }
}

struct TrustStore {
    anchors: Vec<Cert>,
    intermediates: Vec<Cert>,
}

fn pem_to_der(pem: &str) -> Option<Vec<u8>> {
    let b64: String = pem
        .lines()
        .filter(|l| !l.starts_with("-----"))
        .flat_map(|l| l.trim().chars())
        .collect();
    base64::engine::general_purpose::STANDARD.decode(b64).ok()
}

fn trust_store() -> &'static TrustStore {
    static STORE: OnceLock<TrustStore> = OnceLock::new();
    STORE.get_or_init(|| {
        let mut store = TrustStore {
            anchors: Vec::new(),
            intermediates: Vec::new(),
        };
        for pem in BUNDLED_PEMS {
            let Some(cert) = pem_to_der(pem).and_then(|d| Cert::parse(&d).ok()) else {
                continue;
            };
            if cert.subject() == cert.issuer() && cert.signed_by(&cert) {
                store.anchors.push(cert);
            } else {
                store.intermediates.push(cert);
            }
        }
        store
    })
}

/// Builds and checks a chain from `leaf` to a bundled root. Returns whether it is
/// trusted and the common names along the chain.
fn check_chain(
    leaf: &Cert,
    extra: &[Cert],
    at: DateTime<Utc>,
    problems: &mut Vec<String>,
    what: &str,
) -> (bool, Vec<String>) {
    let store = trust_store();
    let label = |c: &Cert| {
        let n = c.name();
        n.common_name.unwrap_or(n.dn)
    };
    let mut names = vec![label(leaf)];
    let mut current = leaf;
    let mut ok = true;
    for _ in 0..10 {
        if !current.valid_at(at) {
            problems.push(format!(
                "{what}: certifikát „{}“ nebyl platný v době {at}",
                label(current)
            ));
            ok = false;
        }
        if store.anchors.iter().any(|a| a.raw == current.raw) {
            return (ok, names);
        }
        let issuer = store
            .anchors
            .iter()
            .chain(store.intermediates.iter())
            .chain(extra.iter().filter(|c| c.is_ca()))
            .find(|c| c.raw != current.raw && current.signed_by(c));
        match issuer {
            Some(i) => {
                names.push(label(i));
                current = i;
            }
            None => {
                problems.push(format!(
                    "{what}: nelze ověřit řetězec, vydavatel „{}“ není mezi důvěryhodnými certifikáty",
                    current.issuer()
                ));
                return (false, names);
            }
        }
    }
    problems.push(format!("{what}: příliš dlouhý řetězec certifikátů"));
    (false, names)
}

// ---------------------------------------------------------------- CMS

fn oid_of(t: &Tlv) -> Option<ObjectIdentifier> {
    (t.tag == 0x06)
        .then(|| ObjectIdentifier::from_bytes(t.content).ok())
        .flatten()
}

/// OID of an AlgorithmIdentifier SEQUENCE.
fn alg_oid(t: &Tlv) -> Option<ObjectIdentifier> {
    ber::children(t.content).ok()?.first().and_then(oid_of)
}

enum SignerId {
    IssuerSerial { issuer: Name, serial: Vec<u8> },
    KeyId(Vec<u8>),
}

struct SignerInfo<'a> {
    sid: SignerId,
    digest: Option<ObjectIdentifier>,
    /// Complete encoding of `[0] signedAttrs`.
    signed_attrs: Option<&'a [u8]>,
    /// Complete encoding of the signature AlgorithmIdentifier.
    sig_alg: Option<&'a [u8]>,
    signature: Vec<u8>,
    /// Content of `[1] unsignedAttrs`.
    unsigned_attrs: Option<&'a [u8]>,
}

struct SignedData<'a> {
    econtent_type: Option<ObjectIdentifier>,
    econtent: Vec<u8>,
    certs: Vec<Cert>,
    signer: SignerInfo<'a>,
}

fn parse_signer_info(si: &[u8]) -> Result<SignerInfo<'_>> {
    let (seq, _) = ber::read(si)?;
    let kids = ber::children_raw(seq.content)?;
    let mut it = kids.iter().skip(1); // version
    let (sid_t, _) = it.next().ok_or_else(|| err("SignerInfo bez sid"))?;
    let sid = if sid_t.tag == 0x30 {
        let parts = ber::children_raw(sid_t.content)?;
        let (Some((_, issuer_raw)), Some((serial, _))) = (parts.first(), parts.get(1)) else {
            return Err(err("neplatný issuerAndSerialNumber"));
        };
        SignerId::IssuerSerial {
            issuer: Name::from_der(issuer_raw).map_err(|e| Error::Zfo(format!("sid: {e}")))?,
            serial: serial.content.to_vec(),
        }
    } else {
        SignerId::KeyId(sid_t.content.to_vec())
    };
    let digest = it.next().and_then(|(t, _)| alg_oid(t));
    let mut signed_attrs = None;
    let mut next = it.next();
    if let Some((t, raw)) = next {
        if t.tag == 0xa0 {
            signed_attrs = Some(*raw);
            next = it.next();
        }
    }
    let sig_alg = next.map(|(_, raw)| *raw);
    let signature = match it.next() {
        Some((t, _)) => ber::octets(t)?,
        None => return Err(err("SignerInfo bez podpisu")),
    };
    let unsigned_attrs = it
        .next()
        .filter(|(t, _)| t.tag == 0xa1)
        .map(|(t, _)| t.content);
    Ok(SignerInfo {
        sid,
        digest,
        signed_attrs,
        sig_alg,
        signature,
        unsigned_attrs,
    })
}

fn parse_signed_data(data: &[u8]) -> Result<SignedData<'_>> {
    let (ci, _) = ber::read(data)?;
    let ci = ber::children(ci.content)?;
    if ci.first().and_then(oid_of) != Some(OID_SIGNED_DATA) {
        return Err(err("není CMS SignedData"));
    }
    let explicit = ci.get(1).ok_or_else(|| err("ContentInfo bez obsahu"))?;
    let (sd, _) = ber::read(explicit.content)?;
    let sd = ber::children_raw(sd.content)?;
    let (eci, _) = sd
        .get(2)
        .ok_or_else(|| err("SignedData bez encapContentInfo"))?;
    let eci = ber::children(eci.content)?;
    let econtent_type = eci.first().and_then(oid_of);
    let econtent = eci.get(1).ok_or_else(|| err("chybí podepsaný obsah"))?;
    let (inner, _) = ber::read(econtent.content)?;
    let econtent = ber::octets(&inner)?;

    let mut certs = Vec::new();
    let mut signer = None;
    for (t, _) in sd.iter().skip(3) {
        match t.tag {
            0xa0 => {
                for (_, raw) in ber::children_raw(t.content)? {
                    // Other certificate choices (attribute certificates) are skipped.
                    if let Ok(c) = Cert::parse(raw) {
                        certs.push(c);
                    }
                }
            }
            0x31 => {
                let infos = ber::children_raw(t.content)?;
                let (_, raw) = infos.first().ok_or_else(|| err("chybí SignerInfo"))?;
                signer = Some(parse_signer_info(raw)?);
            }
            _ => {}
        }
    }
    Ok(SignedData {
        econtent_type,
        econtent,
        certs,
        signer: signer.ok_or_else(|| err("chybí SignerInfo"))?,
    })
}

type Values<'a> = Vec<(Tlv<'a>, &'a [u8])>;

/// Attributes as (type, values with their complete encodings).
fn attributes(content: &[u8]) -> Vec<(ObjectIdentifier, Values<'_>)> {
    ber::children(content)
        .unwrap_or_default()
        .iter()
        .filter_map(|a| {
            let kids = ber::children(a.content).ok()?;
            let oid = oid_of(kids.first()?)?;
            let values = ber::children_raw(kids.get(1)?.content).ok()?;
            Some((oid, values))
        })
        .collect()
}

fn asn1_time(t: &Tlv) -> Option<DateTime<Utc>> {
    let s = std::str::from_utf8(t.content).ok()?.strip_suffix('Z')?;
    let (whole, frac) = s.split_once('.').unwrap_or((s, ""));
    let whole = match t.tag {
        0x17 => {
            let yy: u32 = whole.get(..2)?.parse().ok()?;
            let century = if yy >= 50 { "19" } else { "20" };
            format!("{century}{whole}")
        }
        0x18 => whole.to_string(),
        _ => return None,
    };
    let dt = NaiveDateTime::parse_from_str(&whole, "%Y%m%d%H%M%S").ok()?;
    let nanos = if frac.is_empty() {
        0
    } else {
        format!("{frac:0<9}").get(..9)?.parse::<i64>().ok()?
    };
    Some(dt.and_utc() + chrono::Duration::nanoseconds(nanos))
}

struct SdCheck {
    signature_valid: bool,
    cert: Option<usize>,
    digest: Option<DigestAlg>,
    signing_time: Option<DateTime<Utc>>,
    scheme: Option<SigScheme>,
}

fn find_signer_cert(sd: &SignedData) -> Option<usize> {
    sd.certs.iter().position(|c| match &sd.signer.sid {
        SignerId::IssuerSerial { issuer, serial } => {
            c.issuer() == issuer && c.x.tbs_certificate.serial_number.as_bytes() == serial
        }
        SignerId::KeyId(id) => c.subject_key_id().as_deref() == Some(id),
    })
}

fn check_signed_data(sd: &SignedData, problems: &mut Vec<String>, what: &str) -> SdCheck {
    let si = &sd.signer;
    let digest = si.digest.as_ref().and_then(DigestAlg::from_oid);
    let cert = find_signer_cert(sd);
    let mut check = SdCheck {
        signature_valid: false,
        cert,
        digest,
        signing_time: None,
        scheme: None,
    };
    let Some(digest) = digest else {
        problems.push(format!("{what}: nepodporovaný hashovací algoritmus"));
        return check;
    };
    let Some(cert) = cert.map(|i| &sd.certs[i]) else {
        problems.push(format!("{what}: chybí certifikát podepisujícího"));
        return check;
    };
    let mut digest_ok = true;
    let signed: Vec<u8> = match si.signed_attrs {
        Some(raw) => {
            let (t, _) = match ber::read(raw) {
                Ok(t) => t,
                Err(_) => {
                    problems.push(format!("{what}: neplatné podepsané atributy"));
                    return check;
                }
            };
            let attrs = attributes(t.content);
            let md = attrs
                .iter()
                .find(|(o, _)| *o == OID_MESSAGE_DIGEST)
                .and_then(|(_, v)| v.first())
                .and_then(|(v, _)| ber::octets(v).ok());
            if md.as_deref() != Some(digest.hash(&sd.econtent).as_slice()) {
                problems.push(format!(
                    "{what}: otisk podepsaného obsahu (messageDigest) nesouhlasí – obsah byl změněn"
                ));
                digest_ok = false;
            }
            check.signing_time = attrs
                .iter()
                .find(|(o, _)| *o == OID_SIGNING_TIME)
                .and_then(|(_, v)| v.first())
                .and_then(|(t, _)| asn1_time(t));
            // Signed over the DER SET OF encoding, i.e. with the universal SET tag.
            let mut data = raw.to_vec();
            data[0] = 0x31;
            data
        }
        None => sd.econtent.clone(),
    };
    let sig_digest = si
        .sig_alg
        .and_then(|raw| SigScheme::from_alg_id(raw, Some(digest)));
    check.scheme = sig_digest;
    let sig_ok = match sig_digest {
        Some(d) => cert.rsa_verify(d, &signed, &si.signature),
        None => {
            problems.push(format!("{what}: nepodporovaný podpisový algoritmus"));
            false
        }
    };
    if sig_digest.is_some() && !sig_ok {
        problems.push(format!(
            "{what}: podpis neodpovídá certifikátu podepisujícího"
        ));
    }
    check.signature_valid = digest_ok && sig_ok;
    check
}

/// Verifies an RFC 3161 time stamp token. `expected` gives the imprint the
/// token should carry for a given hash algorithm.
fn check_timestamp(
    token: &[u8],
    expected: &dyn Fn(DigestAlg) -> Option<Vec<u8>>,
    problems: &mut Vec<String>,
    what: &str,
) -> TimestampReport {
    let mut report = TimestampReport {
        gen_time: None,
        hash_algorithm: None,
        imprint_matches: false,
        signature_valid: false,
        serial_number: None,
        tsa: None,
        tsa_issuer: None,
        tsa_cert_not_before: None,
        tsa_cert_not_after: None,
        chain_trusted: None,
    };
    let sd = match parse_signed_data(token) {
        Ok(sd) => sd,
        Err(e) => {
            problems.push(format!("{what}: nelze načíst: {e}"));
            return report;
        }
    };
    if sd.econtent_type != Some(OID_TST_INFO) {
        problems.push(format!("{what}: obsah není TSTInfo"));
    }
    // TSTInfo ::= SEQUENCE { version, policy, messageImprint, serialNumber, genTime, ... }
    let tst = ber::read(&sd.econtent)
        .ok()
        .and_then(|(t, _)| ber::children(t.content).ok())
        .unwrap_or_default();
    if let Some(mi) = tst.get(2).and_then(|t| ber::children(t.content).ok()) {
        let alg = mi
            .first()
            .and_then(alg_oid)
            .as_ref()
            .and_then(DigestAlg::from_oid);
        let hashed = mi.get(1).and_then(|t| ber::octets(t).ok());
        report.hash_algorithm = alg.map(|a| a.name().to_string());
        report.imprint_matches = match (alg, hashed) {
            (Some(a), Some(h)) => expected(a).is_some_and(|e| e == h),
            _ => false,
        };
        if !report.imprint_matches {
            problems.push(format!("{what}: otisk v časovém razítku nesouhlasí"));
        }
    } else {
        problems.push(format!("{what}: chybí messageImprint"));
    }
    report.serial_number = tst.get(3).filter(|t| t.tag == 0x02).map(|t| hex(t.content));
    report.gen_time = tst.get(4).and_then(asn1_time);

    let check = check_signed_data(&sd, problems, what);
    report.signature_valid = check.signature_valid;
    if let Some(cert) = check.cert.map(|i| &sd.certs[i]) {
        report.tsa = Some(cert.name());
        report.tsa_issuer = Some(cert_name(cert.issuer()));
        report.tsa_cert_not_before = cert.not_before();
        report.tsa_cert_not_after = cert.not_after();
        let at = report.gen_time.unwrap_or_else(Utc::now);
        let (mut trusted, _) = check_chain(cert, &sd.certs, at, problems, what);
        if !cert.has_time_stamping_eku() {
            problems.push(format!("{what}: certifikát není určen pro časová razítka"));
            trusted = false;
        }
        report.chain_trusted = Some(trusted);
    }
    report
}

// ---------------------------------------------------------------- dmHash

/// Raw bytes of the `dmDm` element (start tag to end tag inclusive) as in the
/// signed XML; ISDS computes `dmHash` over exactly these bytes.
fn raw_dm_dm(xml: &[u8]) -> Option<&[u8]> {
    let needle = b"dmDm";
    let mut from = 0;
    while let Some(off) = xml[from..].windows(needle.len()).position(|w| w == needle) {
        let pos = from + off;
        from = pos + 1;
        let after = *xml.get(pos + needle.len())?;
        if !(after == b'>' || after == b'/' || after.is_ascii_whitespace()) {
            continue;
        }
        // Walk back over an optional namespace prefix to '<'.
        let mut start = pos;
        while start > 0
            && (xml[start - 1].is_ascii_alphanumeric() || b":_-.".contains(&xml[start - 1]))
        {
            start -= 1;
        }
        if start == 0 || xml[start - 1] != b'<' {
            continue;
        }
        let name = &xml[start..pos + needle.len()];
        let start = start - 1;
        let mut end_tag = b"</".to_vec();
        end_tag.extend_from_slice(name);
        end_tag.push(b'>');
        let end = xml[start..]
            .windows(end_tag.len())
            .position(|w| w == end_tag.as_slice())?;
        return Some(&xml[start..start + end + end_tag.len()]);
    }
    None
}

fn decode_b64(text: &str) -> Option<Vec<u8>> {
    let clean: String = text.split_whitespace().collect();
    base64::engine::general_purpose::STANDARD.decode(clean).ok()
}

// ---------------------------------------------------------------- entry point

/// Verifies the signature of a ZFO file and its time stamps locally (no network).
///
/// Returns an error only when the file cannot be parsed as signed CMS at all;
/// failed checks are reported in the result.
pub fn verify_zfo(zfo: &[u8]) -> Result<SignatureReport> {
    if zfo.trim_ascii_start().starts_with(b"<") {
        return Err(err("soubor není podepsán (obsahuje jen XML)"));
    }
    let sd = parse_signed_data(zfo)?;
    let mut problems = Vec::new();
    let check = check_signed_data(&sd, &mut problems, "Podpis zprávy");
    let cert = check.cert.map(|i| &sd.certs[i]);

    // XML: dmHash and dmQTimestamp.
    let root = xml::parse(&sd.econtent).ok();
    let mut dm_hash_value = None;
    let dm_hash = root.as_ref().and_then(|r| r.find("dmHash")).map(|h| {
        let algorithm = h.attr("algorithm").unwrap_or("SHA-1").to_string();
        let value: String = h.text.split_whitespace().collect();
        dm_hash_value = decode_b64(&value);
        // A delivery info carries the envelope only (no attachments), so the
        // hash of the whole message cannot be recomputed from it.
        let delivery_info = root
            .as_ref()
            .is_some_and(|r| r.find("dmDelivery").is_some() || r.find("dmEvents").is_some());
        let matches_content = (!delivery_info).then(|| {
            let computed = DigestAlg::from_xml_name(&algorithm)
                .zip(raw_dm_dm(&sd.econtent))
                .map(|(a, raw)| a.hash(raw));
            computed.is_some() && computed == dm_hash_value
        });
        if matches_content == Some(false) {
            problems.push("Haš zprávy (dmHash) neodpovídá obsahu zprávy".to_string());
        }
        DmHashReport {
            algorithm,
            value,
            matches_content,
        }
    });

    let timestamp = root
        .as_ref()
        .and_then(|r| r.find("dmQTimestamp"))
        .filter(|t| !t.text.trim().is_empty())
        .map(|t| match decode_b64(&t.text) {
            Some(token) => {
                let expected = |_: DigestAlg| dm_hash_value.clone();
                check_timestamp(&token, &expected, &mut problems, "Časové razítko zprávy")
            }
            None => {
                problems.push("Časové razítko zprávy: neplatné base64".to_string());
                check_timestamp(&[], &|_| None, &mut Vec::new(), "")
            }
        });

    let signature_timestamp = sd.signer.unsigned_attrs.and_then(|ua| {
        let attrs = attributes(ua);
        let (_, values) = attrs.into_iter().find(|(o, _)| *o == OID_TST_ATTR)?;
        let (_, token) = *values.first()?;
        let signature = sd.signer.signature.clone();
        let expected = move |a: DigestAlg| Some(a.hash(&signature));
        Some(check_timestamp(
            token,
            &expected,
            &mut problems,
            "Časové razítko podpisu",
        ))
    });

    let reference_time = check
        .signing_time
        .or(timestamp.as_ref().and_then(|t| t.gen_time))
        .unwrap_or_else(Utc::now);
    let (chain_trusted, chain) = match cert {
        Some(c) => {
            let (ok, names) =
                check_chain(c, &sd.certs, reference_time, &mut problems, "Certifikát");
            (Some(ok), names)
        }
        None => (None, Vec::new()),
    };

    Ok(SignatureReport {
        signature_valid: check.signature_valid,
        signer: cert.map(Cert::name),
        issuer: cert.map(|c| cert_name(c.issuer())),
        cert_serial: cert.map(Cert::serial_hex),
        cert_not_before: cert.and_then(Cert::not_before),
        cert_not_after: cert.and_then(Cert::not_after),
        cert_valid_at_signing: cert.map(|c| c.valid_at(reference_time)),
        signing_time: check.signing_time,
        digest_algorithm: check.digest.map(|d| d.name().to_string()),
        signature_algorithm: check.scheme.map(SigScheme::name),
        chain_trusted,
        chain,
        dm_hash,
        timestamp,
        signature_timestamp,
        problems,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// Locates `reference/datovka-qt/tests/data` in an ancestor of the crate.
    fn data_dir() -> Option<PathBuf> {
        let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        manifest
            .ancestors()
            .map(|a| a.join("reference/datovka-qt/tests/data"))
            .find(|p| p.is_dir())
    }

    fn sample(name: &str) -> Option<Vec<u8>> {
        let path = data_dir()?.join(name);
        let data = std::fs::read(&path).ok();
        if data.is_none() {
            eprintln!("skipping, {} not found", path.display());
        }
        data
    }

    #[test]
    fn bundled_certs_load() {
        let store = trust_store();
        assert_eq!(store.anchors.len(), 3);
        assert_eq!(store.intermediates.len(), 6);
    }

    #[test]
    fn valid_message() {
        let Some(zfo) = sample("DZ_6452235.zfo") else {
            return;
        };
        let r = verify_zfo(&zfo).unwrap();
        assert!(r.signature_valid, "{:?}", r.problems);
        assert_eq!(r.digest_algorithm.as_deref(), Some("SHA-256"));
        assert!(r
            .signer
            .as_ref()
            .and_then(|s| s.common_name.as_deref())
            .unwrap()
            .contains("datových schránek"));
        assert_eq!(
            r.issuer.as_ref().unwrap().common_name.as_deref(),
            Some("PostSignum Qualified CA 2")
        );
        assert!(r.signing_time.is_some());
        assert_eq!(r.chain_trusted, Some(true), "{:?}", r.problems);
        assert_eq!(r.cert_valid_at_signing, Some(true));
        assert_eq!(r.dm_hash.as_ref().unwrap().matches_content, Some(true));
        let ts = r.timestamp.as_ref().unwrap();
        assert!(ts.signature_valid, "{:?}", r.problems);
        assert!(ts.imprint_matches);
        assert_eq!(ts.chain_trusted, Some(true), "{:?}", r.problems);
        assert_eq!(
            ts.gen_time.unwrap().to_rfc3339(),
            "2018-04-25T15:26:34.205+00:00"
        );
        let sts = r.signature_timestamp.as_ref().unwrap();
        assert!(
            sts.signature_valid && sts.imprint_matches,
            "{:?}",
            r.problems
        );
        assert!(r.problems.is_empty(), "{:?}", r.problems);
        // Serializes.
        serde_json::to_string(&r).unwrap();
    }

    #[test]
    fn tampered_dm_hash() {
        let Some(zfo) = sample("DZ_6452235_tampered_dmhash.zfo") else {
            return;
        };
        let r = verify_zfo(&zfo).unwrap();
        // The signed XML was altered: the CMS digest no longer matches and the
        // dmHash neither matches the content nor the time stamp imprint.
        assert!(!r.signature_valid);
        assert_eq!(r.dm_hash.as_ref().unwrap().matches_content, Some(false));
        let ts = r.timestamp.as_ref().unwrap();
        assert!(!ts.imprint_matches);
        assert!(ts.signature_valid);
        assert!(!r.problems.is_empty());
    }

    #[test]
    fn delivery_info_without_signature_time_stamp() {
        let Some(zfo) = sample("DD_5343944_no_time_stamp_token.zfo") else {
            return;
        };
        let r = verify_zfo(&zfo).unwrap();
        assert!(r.signature_valid, "{:?}", r.problems);
        // No time stamp token in the CMS unsigned attributes.
        assert!(r.signature_timestamp.is_none());
        // The envelope time stamp (dmQTimestamp) is there.
        let ts = r.timestamp.as_ref().unwrap();
        assert!(ts.signature_valid && ts.imprint_matches, "{:?}", r.problems);
        assert_eq!(r.dm_hash.as_ref().unwrap().matches_content, None);
    }

    #[test]
    fn other_samples_verify() {
        for name in [
            "DD_6452235.zfo",
            "DDZ_12088458.zfo",
            "DDZ_3401761.zfo",
            "DZ_3401766_binary.zfo",
            "DZ_6872330_binary.zfo",
            "DZ_7057429_binary.zfo",
        ] {
            let Some(zfo) = sample(name) else {
                continue;
            };
            let r = verify_zfo(&zfo).unwrap();
            assert!(r.signature_valid, "{name}: {:?}", r.problems);
            assert!(
                r.dm_hash
                    .as_ref()
                    .is_some_and(|h| h.matches_content != Some(false)),
                "{name}: {:?}",
                r.problems
            );
            if let Some(ts) = &r.timestamp {
                assert!(
                    ts.signature_valid && ts.imprint_matches,
                    "{name}: {:?}",
                    r.problems
                );
            }
            eprintln!(
                "{name}: chain={:?} ts_chain={:?} problems={:?}",
                r.chain_trusted,
                r.timestamp.as_ref().and_then(|t| t.chain_trusted),
                r.problems
            );
        }
    }

    #[test]
    fn unsigned_is_error() {
        assert!(verify_zfo(b"<x/>").is_err());
    }

    #[test]
    fn finds_raw_dm_dm() {
        let xml = b"<a><p:dmDmX/><p:dmDm xmlns:p=\"u\"><p:dmID>1</p:dmID></p:dmDm></a>";
        assert_eq!(
            raw_dm_dm(xml).unwrap(),
            b"<p:dmDm xmlns:p=\"u\"><p:dmID>1</p:dmID></p:dmDm>"
        );
    }
}
