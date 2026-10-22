//! # csqtt-link
//!
//! Cross-platform Rust crate for parsing and decrypting `csqtt://` and `freeturn://` links.
//! FreeTurn uses a plain base64url-encoded JSON payload (no encryption).

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use sha2::{Digest, Sha256};
use std::fmt;
use serde::{Deserialize, Serialize};

pub const CSQTT_CIPHER_KEY_SEED: &str = "csqtt-chiper-key";

#[derive(Debug, thiserror::Error)]
pub enum CsqttLinkError {
    #[error("link does not start with csqtt:// or freeturn://")]
    InvalidScheme,
    #[error("invalid base64 payload: {0}")]
    InvalidBase64(String),
    #[error("payload too short (expected at least {expected} bytes, got {actual})")]
    PayloadTooShort { expected: usize, actual: usize },
    #[error("decryption failed: authentication tag mismatch")]
    DecryptionFailed,
    #[error("decrypted payload is not valid UTF-8")]
    InvalidUtf8,
    #[error("invalid plaintext format: {0}")]
    InvalidFormat(String),
    #[error("missing required parameter: {0}")]
    MissingParameter(String),
    #[error("invalid value for parameter {name}: {value}")]
    InvalidParameter { name: String, value: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CsqttLink {
    pub host: String,
    pub port: u16,
    pub password: String,
    pub hashes: Vec<String>,
    pub vk_access_token: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FreeTurnLink {
    pub v: i32,
    pub provider: String,
    pub peer: String,
    pub transport: String,
    pub mode: String,
    pub bond: bool,
    pub obf: String,
    pub key: String,
    pub n: Option<i32>,
    pub spc: Option<i32>,
    pub cid: String,
    pub listen: String,
    pub dns: String,
    pub dnss: String,
    pub mcap: bool,
    pub name: String,
    // kcp omitted for simplicity, can be parsed as raw string if needed
    pub kcp: Option<serde_json::Value>,
    pub raw_link: String,
}

impl CsqttLink {
    pub fn peer_address(&self) -> String {
        let formatted_host = if self.host.contains(':') && !self.host.starts_with('[') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        format!("{}:{}", formatted_host, self.port)
    }

    pub fn to_link(&self) -> String {
        let mut out = String::from("csqtt://connect?v=2");
        out.push_str("&host=");
        out.push_str(&url_encode(&self.host));
        out.push_str("&peer=");
        out.push_str(&self.port.to_string());
        if !self.password.is_empty() {
            out.push_str("&password=");
            out.push_str(&url_encode(&self.password));
        }
        if !self.hashes.is_empty() {
            out.push_str("&hashes=");
            out.push_str(
                &self.hashes.iter().map(|h| url_encode(h)).collect::<Vec<_>>().join("+"),
            );
        }
        if !self.vk_access_token.is_empty() {
            out.push_str("&token=");
            out.push_str(&url_encode(&self.vk_access_token));
        }
        out
    }
}

impl fmt::Display for CsqttLink {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "csqtt://{}@{}",
            if self.password.is_empty() { "(no-password)" } else { "(password)" },
            self.peer_address()
        )
    }
}

fn derive_cipher_key() -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(CSQTT_CIPHER_KEY_SEED.as_bytes());
    hasher.finalize().into()
}

fn decode_base64_payload(clean: &str) -> Result<Vec<u8>, CsqttLinkError> {
    let mut last_error = String::new();
    let mut try_decode = |engine: &base64::engine::general_purpose::GeneralPurpose, label: &str| {
        match engine.decode(clean.as_bytes()) {
            Ok(bytes) => Some(bytes),
            Err(e) => {
                last_error = format!("{label}: {e}");
                None
            }
        }
    };

    if let Some(bytes) = try_decode(&URL_SAFE_NO_PAD, "urlsafe-nopad")
        .or_else(|| try_decode(&base64::engine::general_purpose::URL_SAFE, "urlsafe"))
    {
        return Ok(bytes);
    }
    if let Some(bytes) =
        try_decode(&base64::engine::general_purpose::STANDARD_NO_PAD, "standard-nopad")
    {
        return Ok(bytes);
    }
    if let Some(bytes) = try_decode(&base64::engine::general_purpose::STANDARD, "standard") {
        return Ok(bytes);
    }
    Err(CsqttLinkError::InvalidBase64(last_error))
}

pub fn parse_csqtt_link(raw: &str) -> Result<CsqttLink, CsqttLinkError> {
    let trimmed = raw.trim();
    let payload = trimmed
        .strip_prefix("csqtt://")
        .ok_or(CsqttLinkError::InvalidScheme)?
        .trim();
    
    // If it's plain connect?..., decrypt not needed
    if payload.starts_with("connect?") {
        return parse_plaintext(payload);
    }
    
    let plaintext = decrypt_csqtt_payload(payload)?;
    parse_plaintext(&plaintext)
}

pub fn decrypt_csqtt_payload(raw_payload: &str) -> Result<String, CsqttLinkError> {
    let clean = raw_payload.replace('\n', "").replace('\r', "").replace(' ', "");
    let bytes = decode_base64_payload(&clean)?;

    const MIN_LEN: usize = 12 + 16;
    if bytes.len() < MIN_LEN {
        return Err(CsqttLinkError::PayloadTooShort {
            expected: MIN_LEN,
            actual: bytes.len(),
        });
    }

    let key_bytes = derive_cipher_key();
    let cipher = Aes256Gcm::new_from_slice(&key_bytes).expect("valid key size");

    let (iv_bytes, ciphertext) = bytes.split_at(12);
    let nonce = Nonce::from_slice(iv_bytes);

    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| CsqttLinkError::DecryptionFailed)?;

    String::from_utf8(plaintext).map_err(|_| CsqttLinkError::InvalidUtf8)
}

pub fn parse_plaintext(plaintext: &str) -> Result<CsqttLink, CsqttLinkError> {
    let candidate = if plaintext.starts_with("csqtt://connect?") {
        plaintext.to_string()
    } else if plaintext.starts_with("connect?") {
        format!("csqtt://{}", plaintext)
    } else if plaintext.starts_with("csqtt://") {
        format!("csqtt://connect?{}", &plaintext[8..])
    } else if plaintext.contains("host=") && plaintext.contains("peer=") {
        format!("csqtt://connect?{}", plaintext)
    } else {
        return Err(CsqttLinkError::InvalidFormat(
            "plaintext does not contain connect? query".into(),
        ));
    };

    let uri = url::Url::parse(&candidate)
        .map_err(|e| CsqttLinkError::InvalidFormat(format!("URL parse error: {e}")))?;

    if !uri.username().is_empty() || uri.password().is_some() {
        return Err(CsqttLinkError::InvalidFormat(
            "userinfo in authority is not allowed".into(),
        ));
    }

    let params = parse_raw_query(uri.query().unwrap_or(""))
        .ok_or_else(|| CsqttLinkError::InvalidFormat("duplicate query keys".into()))?;

    let host = params
        .get("host")
        .ok_or_else(|| CsqttLinkError::MissingParameter("host".into()))
        .map(|s| decode_query_component(s))?;
    if host.is_empty() {
        return Err(CsqttLinkError::MissingParameter("host".into()));
    }

    let port_str = params
        .get("peer")
        .ok_or_else(|| CsqttLinkError::MissingParameter("peer".into()))
        .map(|s| decode_query_component(s))?;
    let port: u16 = port_str
        .parse()
        .map_err(|_| CsqttLinkError::InvalidParameter {
            name: "peer".into(),
            value: port_str.clone(),
        })?;

    let password = params
        .get("password")
        .map(|s| decode_query_component(s))
        .unwrap_or_default();

    let hashes = match params.get("hashes") {
        None => Vec::new(),
        Some(raw) => parse_link_hashes(raw)?,
    };
    let vk_access_token = match params.get("token") {
        None => String::new(),
        Some(raw) => decode_query_component(raw),
    };

    Ok(CsqttLink {
        host,
        port,
        password,
        hashes,
        vk_access_token,
    })
}

// --- FreeTurn ---

pub fn parse_freeturn_link(raw: &str) -> Result<FreeTurnLink, CsqttLinkError> {
    let trimmed = raw.trim();
    let payload = trimmed
        .strip_prefix("freeturn://")
        .ok_or(CsqttLinkError::InvalidScheme)?
        .trim();
    
    let json_bytes = decode_base64_payload(payload)?;
    let json_str = String::from_utf8(json_bytes).map_err(|_| CsqttLinkError::InvalidUtf8)?;
    
    let mut link: FreeTurnLink = serde_json::from_str(&json_str)
        .map_err(|e| CsqttLinkError::InvalidFormat(format!("JSON parse error: {e}")))?;
    
    link.raw_link = raw.to_string();
    
    if link.v != 1 {
        return Err(CsqttLinkError::InvalidFormat(format!("unsupported version: {}", link.v)));
    }
    if link.peer.is_empty() {
        return Err(CsqttLinkError::MissingParameter("peer".into()));
    }
    
    // Defaults
    if link.transport.is_empty() { link.transport = "udp".into(); }
    if link.mode.is_empty() { link.mode = "udp".into(); }
    if link.listen.is_empty() { link.listen = "127.0.0.1:9000".into(); }
    if link.dns.is_empty() { link.dns = "auto".into(); }
    if link.provider.is_empty() { link.provider = "vk".into(); }

    Ok(link)
}

// --- Helpers ---

fn parse_raw_query(raw: &str) -> Option<std::collections::BTreeMap<String, String>> {
    if raw.is_empty() {
        return None;
    }
    let sanitized = raw.replace("&amp;", "&");
    let mut result = std::collections::BTreeMap::new();

    if sanitized.contains('&') || sanitized.contains(';') {
        for part in sanitized.split(['&', ';']) {
            if part.is_empty() {
                continue;
            }
            let (key, value) = match part.split_once('=') {
                Some((k, v)) if !k.is_empty() => (k, v),
                _ => continue,
            };
            let key = decode_query_component(key);
            if key.is_empty() {
                continue;
            }
            if result.contains_key(&key) {
                return None;
            }
            result.insert(key, value.to_string());
        }
        if !result.is_empty() {
            return Some(result);
        }
    }
    None
}

fn decode_query_component(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = hex_val(bytes[i + 1]);
            let lo = hex_val(bytes[i + 2]);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                let byte = (hi << 4) | lo;
                out.push(byte as char);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn parse_link_hashes(raw: &str) -> Result<Vec<String>, CsqttLinkError> {
    let parts: Vec<&str> = raw.split('+').collect();
    let invalid = |reason: String| CsqttLinkError::InvalidParameter {
        name: "hashes".into(),
        value: format!("{} ({reason})", raw),
    };

    if parts.is_empty() || parts.len() > 6 {
        return Err(invalid("expected 1..=6 hashes".into()));
    }

    let mut decoded = Vec::with_capacity(parts.len());
    for part in &parts {
        let d = decode_query_component(part);
        let h = strip_vk_url(&d);
        if h.len() < 16 {
            return Err(invalid(format!("hash too short: len={}", h.len())));
        }
        decoded.push(h);
    }

    Ok(decoded)
}

pub fn strip_vk_url(input: &str) -> String {
    let mut s = input.trim().to_string();
    let prefixes = [
        "https://vk.com/call/join/", "http://vk.com/call/join/",
        "https://m.vk.com/call/join/", "http://m.vk.com/call/join/",
    ];
    let lower = s.to_lowercase();
    for prefix in &prefixes {
        if lower.starts_with(prefix) {
            s = s[prefix.len()..].to_string();
            break;
        }
    }
    s.trim_end_matches('/').to_string()
}

fn url_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for b in input.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => {
                use std::fmt::Write;
                let _ = write!(out, "%{:02X}", b);
            }
        }
    }
    out
}

// C ABI
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[no_mangle]
pub unsafe extern "C" fn csqtt_link_parse(input: *const c_char) -> *mut c_char {
    if input.is_null() { return std::ptr::null_mut(); }
    let c_str = match CStr::from_ptr(input).to_str() {
        Ok(s) => s, Err(_) => return std::ptr::null_mut(),
    };
    
    let res = if c_str.starts_with("freeturn://") {
        match parse_freeturn_link(c_str) {
            Ok(link) => serde_json::to_string(&link).unwrap_or_default(),
            Err(e) => serde_json::json!({"error": e.to_string()}).to_string(),
        }
    } else {
        match parse_csqtt_link(c_str) {
            Ok(link) => serde_json::to_string(&link).unwrap_or_default(),
            Err(e) => serde_json::json!({"error": e.to_string()}).to_string(),
        }
    };

    match CString::new(res) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn csqtt_link_free(ptr: *mut c_char) {
    if !ptr.is_null() { drop(CString::from_raw(ptr)); }
}
