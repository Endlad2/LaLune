//! Настройки: ~/.la-lune/settings.json

use std::path::Path;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default)] pub peer: String,
    #[serde(default, rename = "vkHashes")] pub vk_hashes: String,
    #[serde(default, rename = "vkJsToken")] pub vk_js_token: String,
    #[serde(default, rename = "turnHost")] pub turn_host: String,
    #[serde(default, rename = "turnPort")] pub turn_port: String,
    #[serde(default, rename = "turnTransport")] pub turn_transport: String,
    #[serde(default = "def_workers")] pub workers: i64,
    #[serde(default = "def_aw", rename = "autoApiWorkers")] pub auto_api_workers: i64,
    #[serde(default = "def_obfs")] pub obfs: String,
    #[serde(default = "def_fp")] pub fingerprint: String,
    #[serde(default = "def_cids", rename = "clientIds")] pub client_ids: String,
    #[serde(default = "def_vk_auth", rename = "vkAuthMode")] pub vk_auth_mode: String,
    #[serde(default = "def_captcha", rename = "captchaMode")] pub captcha_mode: String,
    #[serde(default, rename = "deviceId")] pub device_id: String,
    #[serde(default, rename = "autoConnect")] pub auto_connect: bool,
    #[serde(default = "def_auth_mode", rename = "authMode")] pub auth_mode: String,
    #[serde(default, rename = "allowHashRedistribution")] pub allow_hash_redistribution: bool,
    #[serde(default, rename = "validateVkHashes")] pub validate_vk_hashes: bool,
    #[serde(default, rename = "enableSmartTunnel")] pub enable_smart_tunnel: bool,
}

fn def_workers() -> i64 { 9 }
fn def_aw() -> i64 { 9 }
fn def_obfs() -> String { "audio".into() }
fn def_fp() -> String { "chrome".into() }
fn def_cids() -> String { "8202606,6287487".into() }
fn def_vk_auth() -> String { "vkcalls".into() }
fn def_captcha() -> String { "auto".into() }
fn def_auth_mode() -> String { "manual".into() }

impl Default for Settings {
    fn default() -> Self {
        Self {
            peer: String::new(),
            vk_hashes: String::new(),
            vk_js_token: String::new(),
            turn_host: String::new(),
            turn_port: String::new(),
            turn_transport: "udp".into(),
            workers: 9,
            auto_api_workers: 9,
            obfs: "audio".into(),
            fingerprint: "chrome".into(),
            client_ids: "8202606,6287487".into(),
            vk_auth_mode: "vkcalls".into(),
            captcha_mode: "auto".into(),
            device_id: String::new(),
            auto_connect: false,
            auth_mode: "manual".into(),
            allow_hash_redistribution: false,
            validate_vk_hashes: false,
            enable_smart_tunnel: false,
        }
    }
}

pub fn new_device_id() -> String {
    Uuid::new_v4().to_string().replace('-', "")
}

pub fn clamp(s: &mut Settings) {
    if s.workers < 1 { s.workers = 1; }
    if s.workers > 127 { s.workers = 127; }
    if s.auto_api_workers < 9 { s.auto_api_workers = 9; }
    if s.auto_api_workers > 27 { s.auto_api_workers = 27; }
    if s.obfs.is_empty() { s.obfs = "audio".into(); }
    if s.fingerprint.is_empty() { s.fingerprint = "chrome".into(); }
    if s.turn_transport.is_empty() { s.turn_transport = "udp".into(); }
    if s.auth_mode.is_empty() { s.auth_mode = "manual".into(); }
    if s.device_id.is_empty() { s.device_id = new_device_id(); }
}

pub fn load_settings(path: &Path) -> Result<Settings> {
    if !path.exists() {
        let mut s = Settings::default();
        s.device_id = new_device_id();
        save_settings(path, &s)?;
        return Ok(s);
    }
    let raw = std::fs::read_to_string(path)?;
    let mut s: Settings = serde_json::from_str(&raw).unwrap_or_default();
    clamp(&mut s);
    Ok(s)
}

pub fn save_settings(path: &Path, s: &Settings) -> Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let data = serde_json::to_string_pretty(s)?;
    std::fs::write(path, data)?;
    Ok(())
}
