//! # csqtt-link
//!
//! Cross-platform Rust crate for parsing and decrypting `csqtt://` links.
//!
//! ## C ABI (для Android/iOS)
//!
//! Экспортирует `csqtt_link_parse` — возвращает JSON-строку (malloc),
//! которую надо освободить через `csqtt_link_free`.
//! Также `csqtt_link_last_error` — вернуть текст последней ошибки.
//!
//! На Android дополнительно регистрируется `mod jni_wrapper` (см. ниже),
//! который экспортирует `Java_com_lalune_lalune_CsqttLink_nativeParse`
//! и т.д. для вызова из Kotlin.

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use sha2::{Digest, Sha256};
use std::fmt;

pub const CSQTT_CIPHER_KEY_SEED: &str = "csqtt-chiper-key";

#[derive(Debug, thiserror::Error)]
pub enum CsqttLinkError {
    #[error("link does not start with csqtt://")]
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

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CsqttLink {
    pub host: String,
    pub port: u16,
    pub password: String,
    pub hashes: Vec<String>,
    pub vk_access_token: String,
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

pub fn parse_csqtt_link(raw: &str) -> Result<CsqttLink, CsqttLinkError> {
    let trimmed = raw.trim();
    let payload = trimmed
        .strip_prefix("csqtt://")
        .ok_or(CsqttLinkError::InvalidScheme)?
        .trim();
    let plaintext = decrypt_csqtt_payload(payload)?;
    parse_plaintext(&plaintext)
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
    if uri.port().is_some() {
        return Err(CsqttLinkError::InvalidFormat(
            "port in authority is not allowed".into(),
        ));
    }
    if !uri.path().is_empty() && uri.path() != "/" {
        return Err(CsqttLinkError::InvalidFormat("path must be empty".into()));
    }

    let params = parse_raw_query(uri.query().unwrap_or(""))
        .ok_or_else(|| CsqttLinkError::InvalidFormat("duplicate query keys".into()))?;

    let version = params
        .get("v")
        .ok_or_else(|| CsqttLinkError::MissingParameter("v".into()))
        .map(|s| decode_query_component(s))?;
    if version != "2" {
        return Err(CsqttLinkError::InvalidFormat(format!(
            "unsupported version: {}",
            version
        )));
    }

    let host = params
        .get("host")
        .ok_or_else(|| CsqttLinkError::MissingParameter("host".into()))
        .map(|s| decode_query_component(s))?;
    if host.is_empty() {
        return Err(CsqttLinkError::MissingParameter("host".into()));
    }
    if host == "0.0.0.0"
        || host == "127.0.0.1"
        || host == "::1"
        || host.eq_ignore_ascii_case("localhost")
    {
        return Err(CsqttLinkError::InvalidParameter {
            name: "host".into(),
            value: host,
        });
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
    if port == 0 {
        return Err(CsqttLinkError::InvalidParameter {
            name: "peer".into(),
            value: port_str,
        });
    }

    let password = params
        .get("password")
        .map(|s| decode_query_component(s))
        .unwrap_or_default()
        .trim()
        .to_string();
    if !password.is_empty() && password.chars().any(|c| c.is_whitespace()) {
        return Err(CsqttLinkError::InvalidParameter {
            name: "password".into(),
            value: "(whitespace)".into(),
        });
    }

    let hashes = match params.get("hashes") {
        None => Vec::new(),
        Some(raw) => parse_link_hashes(raw)?,
    };
    let vk_access_token = match params.get("token") {
        None => String::new(),
        Some(raw) => parse_vk_token(raw)?,
    };
    if !hashes.is_empty() && !vk_access_token.is_empty() {
        return Err(CsqttLinkError::InvalidFormat(
            "hashes and token are mutually exclusive".into(),
        ));
    }

    Ok(CsqttLink {
        host,
        port,
        password,
        hashes,
        vk_access_token,
    })
}

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
        if !result.is_empty()
            && result.contains_key("v")
            && result.contains_key("host")
            && result.contains_key("peer")
        {
            return Some(result);
        }
    }

    let keys = ["v", "host", "peer", "password", "client", "hashes", "token", "workers"];
    let mut positions: Vec<(usize, &str)> = Vec::new();
    for key in &keys {
        let needle = format!("{}=", key);
        let mut start = 0;
        while let Some(idx) = sanitized[start..].find(&needle) {
            let abs = start + idx;
            let ok = abs == 0 || {
                let prev = sanitized.as_bytes()[abs - 1];
                prev == b'&' || prev == b';' || prev.is_ascii_alphanumeric()
            };
            if ok {
                positions.push((abs, *key));
            }
            start = abs + needle.len();
        }
    }
    positions.sort_by_key(|(p, _)| *p);

    let mut extracted = std::collections::BTreeMap::new();
    for (i, (pos, key)) in positions.iter().enumerate() {
        let value_start = pos + key.len() + 1;
        let value_end = positions
            .get(i + 1)
            .map(|(next, _)| *next)
            .unwrap_or(sanitized.len());
        if value_start > value_end {
            continue;
        }
        let value = sanitized[value_start..value_end].trim_end_matches(['&', ';']);
        if extracted.contains_key(*key) {
            return None;
        }
        extracted.insert((*key).to_string(), value.to_string());
    }
    if !extracted.is_empty()
        && extracted.contains_key("v")
        && extracted.contains_key("host")
        && extracted.contains_key("peer")
    {
        return Some(extracted);
    }

    if !result.is_empty() { Some(result) } else { None }
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
    if parts.iter().any(|p| p.is_empty()) {
        return Err(invalid("empty hash slot".into()));
    }

    let mut decoded = Vec::with_capacity(parts.len());
    for part in &parts {
        let d = decode_query_component(part);
        let h = strip_vk_url(&d);
        if h.len() < 16 {
            return Err(invalid(format!("hash too short: len={}", h.len())));
        }
        if h.chars().any(|c| c.is_whitespace()) {
            return Err(invalid("hash contains whitespace".into()));
        }
        decoded.push(h);
    }

    let mut seen = std::collections::HashSet::new();
    if !decoded.iter().all(|h| seen.insert(h.clone())) {
        return Err(invalid("duplicate hashes".into()));
    }
    Ok(decoded)
}

fn parse_vk_token(raw: &str) -> Result<String, CsqttLinkError> {
    let token = decode_query_component(raw).trim().to_string();
    if token.is_empty() {
        return Err(CsqttLinkError::InvalidParameter {
            name: "token".into(),
            value: raw.into(),
        });
    }
    if token.len() > 4096 || token.chars().any(|c| c.is_whitespace()) {
        return Err(CsqttLinkError::InvalidParameter {
            name: "token".into(),
            value: raw.into(),
        });
    }
    Ok(token)
}

pub fn strip_vk_url(input: &str) -> String {
    let mut s = input.trim().to_string();
    let prefixes = [
        "https://vk.com/call/join/",
        "http://vk.com/call/join/",
        "https://m.vk.com/call/join/",
        "http://m.vk.com/call/join/",
        "m.vk.com/call/join/",
        "vk.com/call/join/",
        "https://vk.ru/call/join/",
        "http://vk.ru/call/join/",
        "https://m.vk.ru/call/join/",
        "http://m.vk.ru/call/join/",
        "m.vk.ru/call/join/",
        "vk.ru/call/join/",
    ];
    let lower = s.to_lowercase();
    for prefix in &prefixes {
        if lower.starts_with(prefix) {
            s = s[prefix.len()..].to_string();
            break;
        }
    }
    if let Some(q) = s.find('?') {
        s.truncate(q);
    }
    if let Some(h) = s.find('#') {
        s.truncate(h);
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

// ============================================================
//  C ABI
// ============================================================

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<CString>> =
        const { std::cell::RefCell::new(None) };
}

fn set_last_error(msg: String) {
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = CString::new(msg).ok();
    });
}

#[no_mangle]
pub unsafe extern "C" fn csqtt_link_parse(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        set_last_error("null input".into());
        return std::ptr::null_mut();
    }
    let c_str = match CStr::from_ptr(input).to_str() {
        Ok(s) => s.to_string(),
        Err(e) => {
            set_last_error(format!("invalid UTF-8: {e}"));
            return std::ptr::null_mut();
        }
    };

    match parse_csqtt_link(&c_str) {
        Ok(link) => {
            let json = match serde_json::to_string(&link) {
                Ok(j) => j,
                Err(e) => {
                    set_last_error(format!("json error: {e}"));
                    return std::ptr::null_mut();
                }
            };
            match CString::new(json) {
                Ok(c) => c.into_raw(),
                Err(e) => {
                    set_last_error(format!("cstring error: {e}"));
                    std::ptr::null_mut()
                }
            }
        }
        Err(e) => {
            set_last_error(e.to_string());
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn csqtt_link_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

#[no_mangle]
pub unsafe extern "C" fn csqtt_link_last_error() -> *const c_char {
    LAST_ERROR.with(|cell| {
        let borrow = cell.borrow();
        match borrow.as_ref() {
            Some(cs) => cs.as_ptr(),
            None => std::ptr::null(),
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn csqtt_link_clear_error() {
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = None;
    });
}

#[no_mangle]
pub unsafe extern "C" fn csqtt_link_decode(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        set_last_error("null input".into());
        return std::ptr::null_mut();
    }
    let c_str = match CStr::from_ptr(input).to_str() {
        Ok(s) => s.to_string(),
        Err(e) => {
            set_last_error(format!("invalid UTF-8: {e}"));
            return std::ptr::null_mut();
        }
    };
    match parse_csqtt_link(&c_str) {
        Ok(link) => match CString::new(link.to_link()) {
            Ok(c) => c.into_raw(),
            Err(e) => {
                set_last_error(format!("cstring error: {e}"));
                std::ptr::null_mut()
            }
        },
        Err(e) => {
            set_last_error(e.to_string());
            std::ptr::null_mut()
        }
    }
}

// ============================================================
//  JNI (только Android)
// ============================================================

#[cfg(target_os = "android")]
mod jni_wrapper;
