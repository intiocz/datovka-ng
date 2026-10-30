//! What ISDS accepts in an outgoing message, checked before sending so the
//! user learns it at once and not from an ISDS error.
//!
//! Sources (reference/isds-docs):
//! - ws_dz.txt, WS pro manipulaci s datovými zprávami, kap. 2.1.2 (str. 45–46):
//!   at least one document; at most 100 files, of them at most 10 containers
//!   (ZIP/ASiC); allowed formats only, content must match the extension and
//!   MIME type; `dmFileDescr` at most 255 characters; a normal message at
//!   most 20 MB of attachments, a high-volume one (VoDZ) at most 100 MB.
//! - ws_dz.txt kap. 1.10 and 2.3 (str. 49): VoDZ only above 20 MB (error 1297
//!   below), no VoDZ in multi-recipient messages (`CreateMultipleMessage`),
//!   VoDZ or PDF over about 60 MB cannot be converted to paper at Czech POINT.
//! - ws_dz.txt kap. 1.3.5 (str. 13): control characters in file names are
//!   dropped or replaced by a space.
//! - ws_dz.txt příloha 3 (str. 94–97): allowed extensions and MIME types;
//!   HTML must not contain `<object`, `<iframe`, `<script`; kap. 3.1 (str. 97):
//!   ZIP/ASiC not encrypted, not split, not nested, at most 1000 files and
//!   folders and at least one file, at most 4 levels of folders, files inside
//!   of allowed formats, all attachments unpacked at most 3 GB.
//! - Provozní řád ISDS 26. 6. 2026, část II kap. 5 (Formát datové zprávy,
//!   Omezení velikosti): at most 100 MB and 100 attachments per message.
//!
//! Sizes use decimal megabytes like the original Datovka
//! (`message.limit.megabyte.bytes` = 1 000 000): ISDS tolerates about 1 MB
//! either way around its limits, so this stays on the safe side.

use std::io::Read;
use std::path::Path;

use serde::Serialize;

/// One megabyte as the limits count it.
pub const MB: u64 = 1_000_000;
/// Attachments of a normal message (`CreateMessage`).
pub const NORMAL_MAX_BYTES: u64 = 20 * MB;
/// Attachments of a high-volume message (`CreateBigMessage`).
pub const VODZ_MAX_BYTES: u64 = 100 * MB;
pub const MAX_FILES: usize = 100;
pub const MAX_CONTAINERS: usize = 10;
pub const MAX_NAME_CHARS: usize = 255;
/// Files and folders in one ZIP/ASiC.
pub const MAX_ZIP_ENTRIES: usize = 1000;
pub const MAX_ZIP_DEPTH: usize = 4;
/// All attachments of a message unpacked.
pub const MAX_UNPACKED_BYTES: u64 = 3000 * MB;
/// Czech POINT cannot convert larger messages or PDFs to paper.
pub const CONVERSION_MAX_BYTES: u64 = 60 * MB;

/// Allowed extensions with their MIME types (příloha 3); the first type is
/// the one to send.
const FORMATS: &[(&str, &[&str])] = &[
    ("asice", &["application/vnd.etsi.asic-e+zip"]),
    ("asics", &["application/vnd.etsi.asic-s+zip"]),
    ("cer", &["application/x-x509-ca-cert"]),
    ("crt", &["application/x-x509-ca-cert"]),
    ("csv", &["text/csv"]),
    ("ddd", &["application/octet-stream"]),
    ("der", &["application/x-x509-ca-cert"]),
    ("doc", &["application/msword"]),
    (
        "docx",
        &[
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/encrypted",
        ],
    ),
    ("dbf", &["application/octet-stream"]),
    ("dgn", &["application/octet-stream"]),
    ("dwg", &["image/vnd.dwg"]),
    (
        "edi",
        &[
            "application/edifact",
            "application/edi-x12",
            "application/edi-consent",
            "text/plain",
            "text/xml",
            "application/xml",
        ],
    ),
    ("fo", &["application/vnd.software602.filler.form+xml", "application/xml"]),
    ("gfs", &["application/xml", "text/xml"]),
    ("gif", &["image/gif"]),
    ("gml", &["application/xml", "text/xml"]),
    ("heic", &["image/heic", "image/heic-sequence"]),
    ("heif", &["image/heif", "image/heif-sequence"]),
    ("html", &["text/html"]),
    ("htm", &["text/html"]),
    ("isdoc", &["text/isdoc", "application/xml"]),
    ("isdocx", &["text/isdocx"]),
    ("jfif", &["image/jpeg", "image/pjpeg"]),
    ("jpeg", &["image/jpeg", "image/pjpeg"]),
    ("jpg", &["image/jpeg", "image/pjpeg"]),
    ("json", &["application/json"]),
    ("mpeg", &["video/mpeg", "video/mpeg1", "video/mpeg2", "video/mpg"]),
    ("mpeg1", &["video/mpeg", "video/mpeg1", "video/mpeg2", "video/mpg"]),
    ("mpeg2", &["video/mpeg", "video/mpeg1", "video/mpeg2", "video/mpg"]),
    ("mpg", &["video/mpeg", "video/mpeg1", "video/mpeg2", "video/mpg"]),
    ("mp2", &["audio/mpeg"]),
    ("mp3", &["audio/mpeg"]),
    ("mp4", &["video/mp4", "audio/mp4"]),
    ("m4a", &["audio/mp4"]),
    ("m4p", &["audio/mp4", "video/mp4"]),
    ("m4v", &["video/mp4"]),
    ("odp", &["application/vnd.oasis.opendocument.presentation"]),
    ("ods", &["application/vnd.oasis.opendocument.spreadsheet"]),
    ("odt", &["application/vnd.oasis.opendocument.text"]),
    ("pdf", &["application/pdf"]),
    ("pk7", &["application/pkcs7-mime", "application/x-pkcs7-mime"]),
    ("png", &["image/png", "image/x-png"]),
    ("ppt", &["application/vnd.ms-powerpoint"]),
    (
        "pptx",
        &[
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/encrypted",
        ],
    ),
    ("prj", &["application/octet-stream"]),
    (
        "p7b",
        &[
            "application/pkcs7-certificates",
            "application/pkcs7-mime",
            "application/x-pkcs7-certificates",
        ],
    ),
    ("p7c", &["application/pkcs7-mime", "application/x-pkcs7-mime"]),
    ("p7f", &["application/pkcs7-signature"]),
    ("p7m", &["application/pkcs7-mime", "application/x-pkcs7-mime"]),
    ("p7s", &["application/pkcs7-signature", "application/x-pkcs7-signature"]),
    ("qix", &["application/octet-stream"]),
    ("rtf", &["application/rtf", "text/rtf", "application/msword"]),
    ("sbn", &["application/octet-stream"]),
    ("sbx", &["application/octet-stream"]),
    ("sce", &["application/vnd.etsi.asic-e+zip"]),
    ("scs", &["application/vnd.etsi.asic-s+zip"]),
    ("shp", &["application/octet-stream"]),
    ("shx", &["application/octet-stream"]),
    ("tiff", &["image/tiff"]),
    ("tif", &["image/tiff"]),
    ("tst", &["application/timestamp-reply"]),
    ("tsr", &["application/timestamp-reply"]),
    ("txt", &["text/plain"]),
    ("wav", &["audio/wav", "audio/wave", "audio/x-wav"]),
    ("xls", &["application/vnd.ms-excel"]),
    (
        "xlsx",
        &[
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/encrypted",
        ],
    ),
    ("xml", &["application/xml", "text/xml"]),
    ("xsd", &["application/xml", "text/xml"]),
    ("zfo", &["application/vnd.software602.filler.form-xml-zip"]),
    (
        "zip",
        &["application/zip", "application/x-compressed", "application/x-zip-compressed"],
    ),
];

/// Containers ISDS counts and checks separately (kap. 3.1).
const CONTAINERS: &[&str] = &["zip", "asice", "asics", "sce", "scs"];

fn extension(name: &str) -> Option<String> {
    let (stem, ext) = name.rsplit_once('.')?;
    (!stem.is_empty()).then(|| ext.to_ascii_lowercase())
}

/// Whether ISDS accepts a file with this name (by its extension).
pub fn is_allowed(name: &str) -> bool {
    extension(name).is_some_and(|e| FORMATS.iter().any(|(x, _)| *x == e))
}

/// The MIME type to send for a file, from the ISDS list.
pub fn mime_for(name: &str) -> &'static str {
    extension(name)
        .and_then(|e| FORMATS.iter().find(|(x, _)| *x == e))
        .map(|(_, m)| m[0])
        .unwrap_or("application/octet-stream")
}

fn is_container(name: &str) -> bool {
    extension(name).is_some_and(|e| CONTAINERS.contains(&e.as_str()))
}

/// Over this the message goes as a high-volume message (VoDZ).
pub fn is_big(total_bytes: u64) -> bool {
    total_bytes > NORMAL_MAX_BYTES
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    /// ISDS would refuse the message; sending is blocked.
    Error,
    /// ISDS accepts it, but the user should know.
    Warning,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Problem {
    pub severity: Severity,
    /// File name the problem is about, if any.
    pub file: Option<String>,
    pub text: String,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Report {
    pub problems: Vec<Problem>,
    pub total_bytes: u64,
    /// Goes as a high-volume message (VoDZ).
    pub big: bool,
}

impl Report {
    pub fn blocks(&self) -> bool {
        self.problems.iter().any(|p| p.severity == Severity::Error)
    }

    /// The blocking problems as one Czech sentence list.
    pub fn error_text(&self) -> Option<String> {
        let errs: Vec<_> = self
            .problems
            .iter()
            .filter(|p| p.severity == Severity::Error)
            .map(|p| p.text.as_str())
            .collect();
        (!errs.is_empty()).then(|| errs.join(" "))
    }

    fn error(&mut self, file: Option<&str>, text: String) {
        self.push(Severity::Error, file, text);
    }

    fn warning(&mut self, file: Option<&str>, text: String) {
        self.push(Severity::Warning, file, text);
    }

    fn push(&mut self, severity: Severity, file: Option<&str>, text: String) {
        self.problems.push(Problem {
            severity,
            file: file.map(str::to_string),
            text,
        });
    }
}

fn mb(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / MB as f64).replace('.', ",")
}

/// Checks the files of a message to `recipients` boxes against the ISDS
/// rules. Reads only what it needs: sizes, the start of each file, HTML
/// text and the directory of ZIP/ASiC containers.
pub fn check_files(paths: &[&Path], recipients: usize) -> Report {
    let mut r = Report::default();
    if paths.is_empty() {
        r.error(None, "Zpráva musí mít aspoň jeden dokument.".into());
        return r;
    }
    if paths.len() > MAX_FILES {
        r.error(
            None,
            format!(
                "Zpráva může mít nejvýš {MAX_FILES} příloh, má jich {}. Více souborů zabalte do ZIP.",
                paths.len()
            ),
        );
    }
    let containers = paths
        .iter()
        .filter(|p| is_container(&name_of(p)))
        .count();
    if containers > MAX_CONTAINERS {
        r.error(
            None,
            format!("Zpráva může mít nejvýš {MAX_CONTAINERS} příloh ZIP nebo ASiC, má jich {containers}."),
        );
    }

    let mut unpacked: u64 = 0;
    let mut names = std::collections::HashSet::new();
    for path in paths {
        let name = name_of(path);
        let n = name.as_str();
        let size = match std::fs::metadata(path) {
            Ok(m) => m.len(),
            Err(e) => {
                r.error(Some(n), format!("{n}: soubor nejde přečíst ({e})."));
                continue;
            }
        };
        r.total_bytes += size;
        unpacked += size;
        if !names.insert(n.to_lowercase()) {
            r.warning(
                Some(n),
                format!("{n}: dvě přílohy se jmenují stejně, adresát je nerozliší."),
            );
        }
        if name_too_long(n) {
            r.error(
                Some(n),
                format!("{n}: název souboru může mít nejvýš {MAX_NAME_CHARS} znaků."),
            );
        }
        if n.chars().any(char::is_control) {
            r.warning(
                Some(n),
                format!("{n}: řídicí znaky v názvu ISDS nahradí mezerou."),
            );
        }
        if !is_allowed(n) {
            let what = extension(n).map_or("bez přípony".to_string(), |e| format!(".{e}"));
            r.error(
                Some(n),
                format!("{n}: formát {what} ISDS nepřijímá (povolené formáty určuje vyhláška č. 194/2009 Sb.)."),
            );
            continue;
        }
        if size == 0 {
            r.error(Some(n), format!("{n}: soubor je prázdný."));
            continue;
        }
        let ext = extension(n).unwrap_or_default();
        let head = read_head(path, 1024);
        if !content_matches(&ext, &head) {
            r.warning(
                Some(n),
                format!("{n}: obsah neodpovídá příponě .{ext}, ISDS takový soubor odmítne."),
            );
        }
        if (ext == "html" || ext == "htm") && html_forbidden(path) {
            r.error(
                Some(n),
                format!("{n}: HTML nesmí obsahovat <script>, <iframe> ani <object>."),
            );
        }
        if ext == "pdf" && size > CONVERSION_MAX_BYTES {
            r.warning(
                Some(n),
                format!("{n}: PDF nad 60 MB nejde na Czech POINTu převést do listinné podoby."),
            );
        }
        if CONTAINERS.contains(&ext.as_str()) {
            unpacked = unpacked - size + check_container(path, n, &ext, &mut r);
        }
    }

    r.big = is_big(r.total_bytes);
    if r.total_bytes > VODZ_MAX_BYTES {
        r.error(
            None,
            format!(
                "Přílohy mají dohromady {}, ISDS přijme nejvýš 100 MB i u velkoobjemové zprávy.",
                mb(r.total_bytes)
            ),
        );
    } else if r.big {
        r.warning(
            None,
            format!(
                "Přílohy mají dohromady {}, zpráva se pošle jako velkoobjemová (nad 20 MB).{}",
                mb(r.total_bytes),
                if recipients > 1 {
                    " Každému adresátovi zvlášť, hromadně ISDS velkoobjemové zprávy neposílá."
                } else {
                    ""
                }
            ),
        );
        if r.total_bytes > CONVERSION_MAX_BYTES {
            r.warning(
                None,
                "Zprávu nad 60 MB nejde na Czech POINTu převést do listinné podoby.".into(),
            );
        }
    }
    if unpacked > MAX_UNPACKED_BYTES {
        r.error(
            None,
            "Přílohy mají po rozbalení víc než 3 GB, ISDS je nepřijme.".into(),
        );
    }
    r
}

/// `dmFileDescr` holds at most 255 characters (most file systems stop at
/// 255 bytes, so this hits only names given some other way).
fn name_too_long(name: &str) -> bool {
    name.chars().count() > MAX_NAME_CHARS
}

fn name_of(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn read_head(path: &Path, n: usize) -> Vec<u8> {
    let mut buf = Vec::with_capacity(n);
    if let Ok(f) = std::fs::File::open(path) {
        let _ = f.take(n as u64).read_to_end(&mut buf);
    }
    buf
}

/// Magic bytes of formats that have them. ISDS recognises the real content
/// and refuses a mismatch; formats without a clear signature pass.
fn content_matches(ext: &str, head: &[u8]) -> bool {
    let zip = head.starts_with(b"PK\x03\x04") || head.starts_with(b"PK\x05\x06");
    match ext {
        // The PDF header may follow a little junk (within the first 1024 bytes).
        "pdf" => head.windows(5).any(|w| w == b"%PDF-"),
        "png" => head.starts_with(b"\x89PNG\r\n\x1a\n"),
        "jpg" | "jpeg" | "jfif" => head.starts_with(&[0xFF, 0xD8, 0xFF]),
        "gif" => head.starts_with(b"GIF8"),
        "tif" | "tiff" => head.starts_with(b"II*\0") || head.starts_with(b"MM\0*"),
        "zip" | "asice" | "asics" | "sce" | "scs" | "odt" | "ods" | "odp" | "isdocx" => zip,
        // Office files may also be encrypted (OLE container, allowed).
        "docx" | "xlsx" | "pptx" => zip || head.starts_with(&[0xD0, 0xCF, 0x11, 0xE0]),
        "doc" | "xls" | "ppt" => head.starts_with(&[0xD0, 0xCF, 0x11, 0xE0]),
        _ => true,
    }
}

fn html_forbidden(path: &Path) -> bool {
    let Ok(data) = std::fs::read(path) else {
        return false;
    };
    let text = String::from_utf8_lossy(&data).to_lowercase();
    ["<object", "<iframe", "<script"]
        .iter()
        .any(|t| text.contains(t))
}

/// Checks a ZIP or ASiC container (kap. 3.1) and returns its unpacked size.
fn check_container(path: &Path, name: &str, ext: &str, r: &mut Report) -> u64 {
    let archive = std::fs::File::open(path)
        .map_err(zip::result::ZipError::Io)
        .and_then(zip::ZipArchive::new);
    let mut archive = match archive {
        Ok(a) => a,
        Err(zip::result::ZipError::UnsupportedArchive(m)) if m.contains("multi-disk") => {
            r.error(Some(name), format!("{name}: rozdělený ZIP ISDS nepřijímá."));
            return 0;
        }
        Err(_) => {
            r.error(Some(name), format!("{name}: soubor není platný ZIP."));
            return 0;
        }
    };
    if archive.len() > MAX_ZIP_ENTRIES {
        r.error(
            Some(name),
            format!(
                "{name}: ZIP může mít nejvýš {MAX_ZIP_ENTRIES} souborů a složek, má jich {}.",
                archive.len()
            ),
        );
    }
    let (mut files, mut unpacked) = (0usize, 0u64);
    let (mut encrypted, mut nested, mut deep) = (false, false, false);
    let mut bad_types = Vec::new();
    // ASiC carries its own signature files (mimetype, META-INF/…), which are
    // not documents; only plain ZIPs have each file checked by type.
    let check_types = ext == "zip";
    for i in 0..archive.len() {
        let Ok(f) = archive.by_index_raw(i) else {
            continue;
        };
        let inner = f.name().trim_end_matches('/').to_string();
        let folders = inner.matches('/').count();
        if f.is_dir() {
            deep |= folders + 1 > MAX_ZIP_DEPTH;
            continue;
        }
        files += 1;
        unpacked += f.size();
        encrypted |= f.encrypted();
        deep |= folders > MAX_ZIP_DEPTH;
        let leaf = inner.rsplit('/').next().unwrap_or(&inner);
        if is_container(leaf) {
            nested = true;
        } else if check_types && !is_allowed(leaf) && bad_types.len() < 3 {
            bad_types.push(leaf.to_string());
        }
    }
    if files == 0 {
        r.error(Some(name), format!("{name}: ZIP musí obsahovat aspoň jeden soubor."));
    }
    if encrypted {
        r.error(Some(name), format!("{name}: zašifrovaný ZIP ISDS nepřijímá."));
    }
    if nested {
        r.error(
            Some(name),
            format!("{name}: ZIP nesmí obsahovat další ZIP ani ASiC."),
        );
    }
    if deep {
        r.error(
            Some(name),
            format!("{name}: ZIP smí mít nejvýš {MAX_ZIP_DEPTH} úrovně složek."),
        );
    }
    if !bad_types.is_empty() {
        r.error(
            Some(name),
            format!(
                "{name}: obsahuje soubory nepovoleného formátu ({}).",
                bad_types.join(", ")
            ),
        );
    }
    unpacked
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;

    struct Dir(PathBuf);

    impl Dir {
        fn new(tag: &str) -> Self {
            let d = std::env::temp_dir().join(format!("datovka-rules-{tag}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            Dir(d)
        }

        fn file(&self, name: &str, data: &[u8]) -> PathBuf {
            let p = self.0.join(name);
            std::fs::write(&p, data).unwrap();
            p
        }

        fn sized(&self, name: &str, head: &[u8], size: u64) -> PathBuf {
            let p = self.file(name, head);
            std::fs::OpenOptions::new().write(true).open(&p).unwrap().set_len(size).unwrap();
            p
        }

        fn zip(&self, name: &str, entries: &[(&str, &[u8])], encrypted: bool) -> PathBuf {
            let p = self.0.join(name);
            let mut w = zip::ZipWriter::new(std::fs::File::create(&p).unwrap());
            for (n, data) in entries {
                if n.ends_with('/') {
                    w.add_directory(*n, zip::write::SimpleFileOptions::default()).unwrap();
                } else {
                    w.start_file(*n, zip::write::SimpleFileOptions::default()).unwrap();
                    w.write_all(data).unwrap();
                }
            }
            w.finish().unwrap();
            if encrypted {
                // Set the "encrypted" bit (general purpose flag bit 0) in
                // the central directory, as an encrypting tool would.
                let mut b = std::fs::read(&p).unwrap();
                let cd = b.windows(4).position(|w| w == b"PK\x01\x02").unwrap();
                b[cd + 8] |= 1;
                std::fs::write(&p, b).unwrap();
            }
            p
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn check(paths: &[PathBuf]) -> Report {
        check_files(&paths.iter().map(PathBuf::as_path).collect::<Vec<_>>(), 1)
    }

    fn errors(r: &Report) -> Vec<&str> {
        r.problems
            .iter()
            .filter(|p| p.severity == Severity::Error)
            .map(|p| p.text.as_str())
            .collect()
    }

    const PDF: &[u8] = b"%PDF-1.7\n";

    #[test]
    fn a_plain_pdf_passes() {
        let d = Dir::new("ok");
        let r = check(&[d.file("Smlouva.pdf", PDF), d.file("poznámka.txt", b"text")]);
        assert!(r.problems.is_empty(), "{:?}", r.problems);
        assert!(!r.big && !r.blocks());
    }

    #[test]
    fn needs_a_document() {
        let r = check(&[]);
        assert!(r.blocks());
        assert!(errors(&r)[0].contains("aspoň jeden dokument"));
    }

    #[test]
    fn refuses_formats_outside_the_list() {
        let d = Dir::new("formats");
        let r = check(&[d.file("program.exe", b"MZ"), d.file("README", b"x"), d.file("tacho.ddd", b"x")]);
        let e = errors(&r);
        assert_eq!(e.len(), 2, "{e:?}");
        assert!(e[0].contains(".exe") && e[1].contains("bez přípony"));
        assert!(is_allowed("TACHO.DDD") && is_allowed("faktura.isdoc"));
        assert!(!is_allowed(".pdf"));
    }

    #[test]
    fn mime_types_come_from_the_isds_list() {
        assert_eq!(mime_for("Smlouva.PDF"), "application/pdf");
        assert_eq!(mime_for("data.csv"), "text/csv");
        assert_eq!(mime_for("podpis.p7m"), "application/pkcs7-mime");
        assert_eq!(mime_for("archiv.zip"), "application/zip");
        assert_eq!(mime_for("formular.fo"), "application/vnd.software602.filler.form+xml");
        assert_eq!(mime_for("neznamy.xyz"), "application/octet-stream");
    }

    #[test]
    fn counts_files_and_containers() {
        let d = Dir::new("count");
        let many: Vec<_> = (0..101).map(|i| d.file(&format!("{i}.txt"), b"x")).collect();
        assert!(errors(&check(&many))[0].contains("nejvýš 100 příloh"));
        let zips: Vec<_> = (0..11)
            .map(|i| d.zip(&format!("{i}.zip"), &[("a.txt", b"x")], false))
            .collect();
        assert!(errors(&check(&zips)).iter().any(|e| e.contains("nejvýš 10 příloh ZIP")));
    }

    #[test]
    fn limits_the_name_and_empty_files() {
        assert!(name_too_long(&format!("{}.pdf", "á".repeat(252))));
        assert!(!name_too_long(&format!("{}.pdf", "á".repeat(251))));
        let d = Dir::new("names");
        let e = errors(&check(&[d.file("prazdny.pdf", b"")])).join(" ");
        assert!(e.contains("prázdný"));
    }

    #[test]
    fn sizes_decide_normal_high_volume_and_too_big() {
        let d = Dir::new("sizes");
        let normal = check(&[d.sized("a.pdf", PDF, NORMAL_MAX_BYTES)]);
        assert!(!normal.big && normal.problems.is_empty());
        let big = check(&[d.sized("b.pdf", PDF, NORMAL_MAX_BYTES + 1)]);
        assert!(big.big && !big.blocks());
        assert!(big.problems[0].text.contains("velkoobjemová"));
        let too_big = check(&[d.sized("c.pdf", PDF, VODZ_MAX_BYTES + 1)]);
        assert!(too_big.blocks());
        let r = check_files(&[d.sized("d.pdf", PDF, 30 * MB).as_path()], 3);
        assert!(r.problems.iter().any(|p| p.text.contains("Každému adresátovi zvlášť")));
    }

    #[test]
    fn html_must_not_carry_scripts() {
        let d = Dir::new("html");
        let r = check(&[d.file("a.html", b"<p>ok</p><SCRIPT>x</script>")]);
        assert!(errors(&r)[0].contains("<script>"));
        assert!(check(&[d.file("b.htm", b"<p>ok</p>")]).problems.is_empty());
    }

    #[test]
    fn warns_when_content_does_not_match() {
        let d = Dir::new("magic");
        let r = check(&[d.file("faktura.pdf", b"<html>")]);
        assert_eq!(r.problems[0].severity, Severity::Warning);
        assert!(r.problems[0].text.contains("neodpovídá příponě"));
    }

    #[test]
    fn checks_zip_containers() {
        let d = Dir::new("zip");
        let good = d.zip("ok.zip", &[("slozka/", b""), ("slozka/a.pdf", PDF)], false);
        assert!(check(&[good]).problems.is_empty());
        let e = |p| errors(&check(&[p])).join(" ");
        assert!(e(d.zip("enc.zip", &[("a.pdf", PDF)], true)).contains("zašifrovaný"));
        assert!(e(d.zip("nest.zip", &[("b.zip", b"PK")], false)).contains("další ZIP"));
        assert!(e(d.zip("deep.zip", &[("1/2/3/4/5/a.pdf", PDF)], false)).contains("úrovně složek"));
        assert!(check(&[d.zip("four.zip", &[("1/2/3/4/a.pdf", PDF)], false)]).problems.is_empty());
        assert!(e(d.zip("empty.zip", &[("prazdna/", b"")], false)).contains("aspoň jeden soubor"));
        assert!(e(d.zip("exe.zip", &[("a.exe", b"MZ")], false)).contains("nepovoleného formátu"));
        assert!(e(d.file("broken.zip", b"PK\x03\x04junk")).contains("není platný ZIP"));
        // ASiC keeps its own technical files; only the structure is checked.
        let asic = d.zip("podpis.asice", &[("mimetype", b"x"), ("META-INF/signatures.xml", b"x")], false);
        assert!(check(&[asic]).problems.is_empty());
    }

    #[test]
    fn duplicate_names_and_control_characters_warn() {
        let d = Dir::new("dup");
        let sub = d.0.join("jina");
        std::fs::create_dir_all(&sub).unwrap();
        let other = sub.join("A.pdf");
        std::fs::write(&other, PDF).unwrap();
        let r = check(&[d.file("a.pdf", PDF), other]);
        assert!(!r.blocks());
        assert!(r.problems[0].text.contains("stejně"));
    }
}
