//! Minimal namespace-agnostic XML tree, enough for ISDS SOAP responses and ZFO content.

use quick_xml::events::Event;
use quick_xml::Reader;

use crate::error::{Error, Result};

#[derive(Debug, Clone, Default)]
pub struct Element {
    /// Local name without namespace prefix.
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub children: Vec<Element>,
    pub text: String,
}

fn local(name: &[u8]) -> String {
    let name = String::from_utf8_lossy(name);
    match name.rsplit_once(':') {
        Some((_, l)) => l.to_string(),
        None => name.into_owned(),
    }
}

pub fn parse(input: &[u8]) -> Result<Element> {
    let mut reader = Reader::from_reader(input);
    reader.config_mut().trim_text(false);
    let mut stack: Vec<Element> = vec![Element::default()];
    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                stack.push(start_element(&e)?);
            }
            Ok(Event::Empty(e)) => {
                let el = start_element(&e)?;
                stack.last_mut().unwrap().children.push(el);
            }
            Ok(Event::End(_)) => {
                let el = stack.pop().unwrap();
                match stack.last_mut() {
                    Some(parent) => parent.children.push(el),
                    None => return Err(Error::Xml("nespárovaný koncový tag".into())),
                }
            }
            Ok(Event::Text(t)) => {
                let s = t.unescape().map_err(|e| Error::Xml(e.to_string()))?;
                stack.last_mut().unwrap().text.push_str(&s);
            }
            Ok(Event::CData(t)) => {
                stack
                    .last_mut()
                    .unwrap()
                    .text
                    .push_str(&String::from_utf8_lossy(&t));
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(e) => return Err(Error::Xml(e.to_string())),
        }
        buf.clear();
    }
    let mut root = stack
        .pop()
        .ok_or_else(|| Error::Xml("prázdný dokument".into()))?;
    if !stack.is_empty() {
        return Err(Error::Xml("neukončený element".into()));
    }
    root.children
        .pop()
        .ok_or_else(|| Error::Xml("dokument bez kořenového elementu".into()))
}

fn start_element(e: &quick_xml::events::BytesStart) -> Result<Element> {
    let mut el = Element {
        name: local(e.name().as_ref()),
        ..Default::default()
    };
    for a in e.attributes() {
        let a = a.map_err(|e| Error::Xml(e.to_string()))?;
        // Namespace declarations are not data; `xmlns:q` would become `q`.
        let key = a.key.as_ref();
        if key == b"xmlns" || key.starts_with(b"xmlns:") {
            continue;
        }
        let v = a
            .unescape_value()
            .map_err(|e| Error::Xml(e.to_string()))?
            .into_owned();
        el.attrs.push((local(a.key.as_ref()), v));
    }
    Ok(el)
}

impl Element {
    pub fn child(&self, name: &str) -> Option<&Element> {
        self.children.iter().find(|c| c.name == name)
    }

    pub fn children_named<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Element> {
        self.children.iter().filter(move |c| c.name == name)
    }

    /// Depth-first search for the first descendant (or self) with the given name.
    pub fn find(&self, name: &str) -> Option<&Element> {
        if self.name == name {
            return Some(self);
        }
        self.children.iter().find_map(|c| c.find(name))
    }

    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    /// Trimmed text of a direct child, `None` when missing, empty or `xsi:nil`.
    pub fn child_text(&self, name: &str) -> Option<String> {
        let c = self.child(name)?;
        if c.attr("nil") == Some("true") {
            return None;
        }
        let t = c.text.trim();
        (!t.is_empty()).then(|| t.to_string())
    }
}

/// Escape text for inclusion in an XML document.
pub fn escape(s: &str) -> String {
    quick_xml::escape::escape(s).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_namespaced_document() {
        let doc = br#"<?xml version="1.0"?>
            <s:Envelope xmlns:s="x"><s:Body><p:R xmlns:p="y" p:a="1">
              <p:v>hi &amp; bye</p:v><p:n xsi:nil="true"/></p:R></s:Body></s:Envelope>"#;
        let root = parse(doc).unwrap();
        assert_eq!(root.name, "Envelope");
        let r = root.find("R").unwrap();
        assert_eq!(r.attr("a"), Some("1"));
        assert_eq!(r.attrs.len(), 1, "xmlns:p is not an attribute");
        assert_eq!(r.child_text("v").as_deref(), Some("hi & bye"));
        assert_eq!(r.child_text("n"), None);
    }
}
