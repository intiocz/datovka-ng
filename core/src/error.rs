use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("{}", net_text(.0))]
    Http(#[from] reqwest::Error),
    #[error("ISDS vrátil HTTP {status}: {body}")]
    HttpStatus { status: u16, body: String },
    #[error("přihlášení odmítnuto (špatné jméno, heslo nebo kód)")]
    Unauthorized,
    /// `code` is the numeric ISDS status, or a word for errors of this app
    /// (`password`, `account`), which only show their text.
    #[error("{}", isds_text(code, text))]
    Isds { code: String, text: String },
    #[error("neplatné XML: {0}")]
    Xml(String),
    #[error("neplatný ZFO soubor: {0}")]
    Zfo(String),
    #[error("chyba souboru: {0}")]
    Io(#[from] std::io::Error),
    #[error("chyba JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("chyba databáze: {0}")]
    Db(#[from] rusqlite::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

/// The network failure in words, without reqwest's English.
fn net_text(e: &reqwest::Error) -> String {
    let host = e
        .url()
        .and_then(|u| u.host_str())
        .map(|h| format!(" ({h})"))
        .unwrap_or_default();
    if e.is_timeout() {
        format!("server neodpověděl včas{host}, zkuste to znovu")
    } else if e.is_connect() {
        format!("nepodařilo se spojit se serverem{host}, zkontrolujte připojení k internetu")
    } else if e.is_request() || e.is_body() {
        format!("spojení se serverem se přerušilo{host}, zkuste to znovu")
    } else if e.is_decode() {
        format!("server poslal nečitelnou odpověď{host}")
    } else {
        format!("chyba sítě{host}: {e}")
    }
}

fn isds_text(code: &str, text: &str) -> String {
    if !code.is_empty() && code.bytes().all(|b| b.is_ascii_digit()) {
        format!("ISDS chyba {code}: {text}")
    } else {
        text.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isds_codes_are_shown_only_when_they_come_from_isds() {
        let isds = Error::Isds { code: "1214".into(), text: "schránka neexistuje".into() };
        assert_eq!(isds.to_string(), "ISDS chyba 1214: schránka neexistuje");
        let own = Error::Isds { code: "password".into(), text: "heslo není uložené".into() };
        assert_eq!(own.to_string(), "heslo není uložené");
    }

    #[tokio::test]
    async fn a_network_failure_reads_in_czech() {
        // Port 9 (discard) is closed on any test machine.
        let e: Error = reqwest::get("http://127.0.0.1:9/").await.unwrap_err().into();
        assert_eq!(
            e.to_string(),
            "nepodařilo se spojit se serverem (127.0.0.1), zkontrolujte připojení k internetu"
        );
    }
}
