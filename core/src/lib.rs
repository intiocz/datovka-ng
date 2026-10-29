//! Core of DATOVKA: ISDS client, ZFO handling and the data of the original Datovka.

pub mod ai;
mod ber;
mod envelope;
pub mod error;
pub mod isds;
pub mod legacy;
pub mod model;
pub mod records;
pub mod verify;
mod xml;
pub mod zfo;

pub use error::{Error, Result};

/// Optional proxy for all connections (ISDS, AI, records management), set by
/// the app; without it the system proxy settings apply.
static PROXY: std::sync::RwLock<Option<String>> = std::sync::RwLock::new(None);

pub fn set_proxy(url: Option<String>) {
    *PROXY.write().unwrap() = url.filter(|u| !u.trim().is_empty());
}

/// A client builder with the configured proxy.
pub(crate) fn http_builder() -> reqwest::ClientBuilder {
    // A phone suspends the app and the server drops idle connections
    // meanwhile; do not reuse one that sat around.
    let b = reqwest::Client::builder().pool_idle_timeout(std::time::Duration::from_secs(15));
    match PROXY
        .read()
        .unwrap()
        .as_deref()
        .and_then(|u| reqwest::Proxy::all(u).ok())
    {
        Some(p) => b.proxy(p),
        None => b,
    }
}
