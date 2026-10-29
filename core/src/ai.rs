//! AI assistant: reads message attachments on request and extracts deadlines
//! and events for the calendar. Uses the Claude Messages API over HTTPS.
//! Nothing is sent unless the user asks for an analysis of a message.

use base64::Engine;
use serde_json::{json, Value};

use crate::error::{Error, Result};

const API_URL: &str = "https://api.anthropic.com/v1/messages";
const MODEL: &str = "claude-opus-5-5";

/// A document to analyse.
pub struct AiFile {
    pub name: String,
    pub mime: Option<String>,
    pub data: Vec<u8>,
}

/// JSON schema of the answer; every field required, no extra fields
/// (structured outputs need a closed schema). Empty strings mean "unknown".
fn schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "suggested_deadline", "events"],
        "properties": {
            "summary": {
                "type": "string",
                "description": "Dvě až tři věty česky: co úřad chce a co má adresát udělat."
            },
            "suggested_deadline": {
                "type": "string",
                "description": "Nejbližší lhůta, do kdy musí adresát jednat, ve formátu YYYY-MM-DD, nebo prázdný řetězec."
            },
            "events": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["title", "date", "time", "end_time", "kind", "location", "description", "source"],
                    "properties": {
                        "title": {"type": "string"},
                        "date": {"type": "string", "description": "YYYY-MM-DD"},
                        "time": {"type": "string", "description": "HH:MM, nebo prázdné pro celodenní událost"},
                        "end_time": {"type": "string", "description": "HH:MM, nebo prázdné"},
                        "kind": {"type": "string", "enum": ["lhuta", "jednani", "platba", "schuzka", "jine"]},
                        "location": {"type": "string"},
                        "description": {"type": "string"},
                        "source": {"type": "string", "description": "Krátká doslovná citace z dokumentu, ze které termín plyne."}
                    }
                }
            }
        }
    })
}

/// Instructions for the model; `meta` describes the message (sender, subject,
/// delivery date) so relative deadlines ("do 15 dnů od doručení") resolve.
pub fn instructions(meta: &str) -> String {
    format!(
        "Jsi asistent pro datové schránky. V příloze jsou dokumenty z jedné datové zprávy.\n\
         Údaje o zprávě:\n{meta}\n\n\
         Najdi v dokumentech všechny termíny, na které musí adresát reagovat nebo se \
         dostavit: lhůty k vyjádření, odvolání nebo doplnění, platby a splatnosti, \
         jednání, kontroly a schůzky. Lhůty počítané od doručení přepočítej na konkrétní \
         datum podle data doručení (podle českých pravidel: lhůta začíná dnem následujícím \
         po doručení, a když konec připadne na sobotu, neděli nebo svátek, posouvá se na \
         nejbližší pracovní den). Nevymýšlej termíny, které z dokumentů neplynou; když \
         žádné nejsou, vrať prázdný seznam. Piš česky."
    )
}

fn content_blocks(meta: &str, files: &[AiFile]) -> Vec<Value> {
    let mut blocks = Vec::new();
    let mut skipped = Vec::new();
    for f in files {
        let lower = f.name.to_lowercase();
        let mime = f.mime.as_deref().unwrap_or("");
        if mime == "application/pdf" || lower.ends_with(".pdf") {
            blocks.push(json!({
                "type": "document",
                "source": {
                    "type": "base64",
                    "media_type": "application/pdf",
                    "data": base64::engine::general_purpose::STANDARD.encode(&f.data),
                },
                "title": f.name,
            }));
        } else if mime.starts_with("text/")
            || [".txt", ".xml", ".html", ".htm", ".csv", ".isdoc"]
                .iter()
                .any(|e| lower.ends_with(e))
        {
            blocks.push(json!({
                "type": "document",
                "source": {
                    "type": "text",
                    "media_type": "text/plain",
                    "data": String::from_utf8_lossy(&f.data),
                },
                "title": f.name,
            }));
        } else {
            skipped.push(f.name.clone());
        }
    }
    let mut text = instructions(meta);
    if !skipped.is_empty() {
        text += &format!(
            "\n\nTyto přílohy nebylo možné přiložit (nepodporovaný formát): {}.",
            skipped.join(", ")
        );
    }
    blocks.push(json!({"type": "text", "text": text}));
    blocks
}

/// Request body for the Messages API.
pub fn request_body(meta: &str, files: &[AiFile]) -> Value {
    json!({
        "model": MODEL,
        "max_tokens": 16000,
        // Declined requests are re-run server-side on a suitable model.
        "fallbacks": "default",
        "output_config": {
            "effort": "medium",
            "format": {"type": "json_schema", "schema": schema()},
        },
        "messages": [{"role": "user", "content": content_blocks(meta, files)}],
    })
}

/// Extracts the JSON answer from a Messages API response.
pub fn parse_response(resp: &Value) -> Result<Value> {
    if resp.get("type").and_then(Value::as_str) == Some("error") {
        let msg = resp
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("neznámá chyba");
        return Err(Error::Isds {
            code: "ai".into(),
            text: format!("Claude API: {msg}"),
        });
    }
    if resp.get("stop_reason").and_then(Value::as_str) == Some("refusal") {
        return Err(Error::Isds {
            code: "ai".into(),
            text: "model rozbor dokumentů odmítl".into(),
        });
    }
    let text: String = resp
        .get("content")
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|b| b.get("text").and_then(Value::as_str))
                .collect()
        })
        .unwrap_or_default();
    serde_json::from_str(text.trim()).map_err(|e| Error::Isds {
        code: "ai".into(),
        text: format!("odpověď modelu není platný JSON: {e}"),
    })
}

/// Sends the documents to Claude and returns `{summary, suggested_deadline, events}`.
pub async fn analyze(api_key: &str, meta: &str, files: &[AiFile]) -> Result<Value> {
    if files.is_empty() {
        return Err(Error::Isds {
            code: "ai".into(),
            text: "zpráva nemá žádné přílohy k rozboru".into(),
        });
    }
    let http = crate::http_builder()
        .timeout(std::time::Duration::from_secs(300))
        .build()?;
    let body = serde_json::to_vec(&request_body(meta, files))?;
    let resp = http
        .post(API_URL)
        .header("content-type", "application/json")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("anthropic-beta", "server-side-fallback-2026-07-01")
        .body(body)
        .send()
        .await?;
    let status = resp.status();
    let text = resp.text().await?;
    let value: Value = serde_json::from_str(&text).map_err(|_| Error::HttpStatus {
        status: status.as_u16(),
        body: text.chars().take(300).collect(),
    })?;
    parse_response(&value)
}

/// Prompt for the local Claude Code CLI (`claude -p`), which reads the files
/// itself and must answer with JSON only.
pub fn cli_prompt(meta: &str, paths: &[String]) -> String {
    format!(
        "{}\n\nDokumenty jsou v souborech (přečti je):\n{}\n\n\
         Odpověz POUZE jedním JSON objektem bez dalšího textu, podle tohoto JSON schématu:\n{}",
        instructions(meta),
        paths.join("\n"),
        serde_json::to_string_pretty(&schema()).unwrap_or_default()
    )
}

/// Pulls the first JSON object out of free text (CLI answers may add prose).
pub fn json_from_text(text: &str) -> Result<Value> {
    let start = text.find('{');
    let end = text.rfind('}');
    match (start, end) {
        (Some(s), Some(e)) if e > s => {
            serde_json::from_str(&text[s..=e]).map_err(|err| Error::Isds {
                code: "ai".into(),
                text: format!("odpověď není platný JSON: {err}"),
            })
        }
        _ => Err(Error::Isds {
            code: "ai".into(),
            text: "odpověď neobsahuje JSON".into(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_request_with_pdf_and_text() {
        let files = [
            AiFile {
                name: "vyzva.pdf".into(),
                mime: Some("application/pdf".into()),
                data: b"%PDF".to_vec(),
            },
            AiFile {
                name: "info.txt".into(),
                mime: None,
                data: b"ahoj".to_vec(),
            },
            AiFile {
                name: "foto.jpg".into(),
                mime: None,
                data: vec![1],
            },
        ];
        let body = request_body("Věc: test", &files);
        let content = body
            .pointer("/messages/0/content")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(
            content[0].pointer("/source/media_type").unwrap(),
            "application/pdf"
        );
        assert_eq!(content[1].pointer("/source/type").unwrap(), "text");
        let text = content[2]["text"].as_str().unwrap();
        assert!(text.contains("foto.jpg"));
        assert_eq!(body["model"], MODEL);
        assert_eq!(
            body.pointer("/output_config/format/type").unwrap(),
            "json_schema"
        );
    }

    #[test]
    fn parses_answer_and_refusal() {
        let ok = json!({"stop_reason": "end_turn", "content": [
            {"type": "thinking", "thinking": ""},
            {"type": "text", "text": "{\"summary\":\"s\",\"suggested_deadline\":\"\",\"events\":[]}"}
        ]});
        assert_eq!(parse_response(&ok).unwrap()["summary"], "s");
        let refused = json!({"stop_reason": "refusal", "content": []});
        assert!(parse_response(&refused).is_err());
        assert_eq!(json_from_text("Tady:\n{\"a\":1}\nhotovo").unwrap()["a"], 1);
    }
}
