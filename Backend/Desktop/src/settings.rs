// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Настройки: чтение/запись settings.json, дефолты, валидация диапазонов.

use serde::{Deserialize, Serialize};

pub const DEFAULT_WORKERS: i32 = 9;
pub const MIN_WORKERS: i32 = 1;
pub const MAX_WORKERS: i32 = 127;
pub const DEFAULT_AUTO_API_WORKERS: i32 = 9;
pub const MIN_AUTO_API_WORKERS: i32 = 9;
pub const MAX_AUTO_API_WORKERS: i32 = 27;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub peer: String,
    pub vk_hashes: String,
    pub vk_js_token: String,

    pub workers: i32,
    pub auto_api_workers: i32,

    pub password: String,
    pub obfs: String,
    pub fingerprint: String,
    pub client_ids: String,
    pub device_id: String,

    pub auth_mode: String,
    pub turn_transport: String,
    pub turn_host: String,
    pub turn_port: String,
    pub captcha_mode: String,
    pub vk_auth_mode: String,

    pub allow_hash_redistribution: bool,
    pub validate_vk_hashes: bool,

    pub enable_smart_tunnel: bool,

    /// Показывать логи ядра (строки с префиксом `[CORE]`) на вкладке Логи.
    pub show_core_logs: bool,

    /// Раздавать VPN через SOCKS5 на 0.0.0.0:1080.
    pub share_vpn: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            peer: String::new(),
            vk_hashes: String::new(),
            vk_js_token: String::new(),

            workers: DEFAULT_WORKERS,
            auto_api_workers: DEFAULT_AUTO_API_WORKERS,

            password: String::new(),
            obfs: "video".into(),
            fingerprint: "firefox".into(),
            client_ids: "8202606,6287487".into(),
            device_id: String::new(),

            auth_mode: "manual".into(),
            turn_transport: "udp".into(),
            turn_host: String::new(),
            turn_port: String::new(),
            captcha_mode: "auto".into(),
            vk_auth_mode: "vkcalls".into(),

            allow_hash_redistribution: false,
            validate_vk_hashes: false,

            enable_smart_tunnel: false,
            show_core_logs: false,
            share_vpn: false,
        }
    }
}

impl Settings {
    pub fn normalize(&mut self) {
        if self.workers < MIN_WORKERS { self.workers = MIN_WORKERS; }
        if self.workers > MAX_WORKERS { self.workers = MAX_WORKERS; }

        if self.auto_api_workers < MIN_AUTO_API_WORKERS { self.auto_api_workers = MIN_AUTO_API_WORKERS; }
        if self.auto_api_workers > MAX_AUTO_API_WORKERS { self.auto_api_workers = MAX_AUTO_API_WORKERS; }

        if self.auth_mode.is_empty() { self.auth_mode = "manual".into(); }
        if self.turn_transport.is_empty() { self.turn_transport = "udp".into(); }
        if self.obfs.is_empty() { self.obfs = "video".into(); }
        if self.fingerprint.is_empty() { self.fingerprint = "firefox".into(); }
        if self.captcha_mode.is_empty() { self.captcha_mode = "auto".into(); }
        if self.vk_auth_mode.is_empty() { self.vk_auth_mode = "vkcalls".into(); }
        if self.client_ids.is_empty() { self.client_ids = "8202606,6287487".into(); }

        if self.device_id.is_empty() {
            self.device_id = uuid::Uuid::new_v4().to_string().replace('-', "");
        }
    }

    pub fn merge_from_json(&mut self, value: serde_json::Value) -> anyhow::Result<()> {
        let mut base = serde_json::to_value(&*self)?;
        if let (Some(base_obj), Some(patch_obj)) = (base.as_object_mut(), value.as_object()) {
            for (k, v) in patch_obj {
                base_obj.insert(k.clone(), v.clone());
            }
        }
        let merged: Settings = serde_json::from_value(base)?;
        *self = merged;
        self.normalize();
        Ok(())
    }

    pub fn get_field(&self, key: &str) -> Option<serde_json::Value> {
        let v = serde_json::to_value(self).ok()?;
        v.get(key).cloned()
    }

    pub fn set_field(&mut self, key: &str, value: serde_json::Value) -> anyhow::Result<()> {
        let mut v = serde_json::to_value(&*self)?;
        if let Some(obj) = v.as_object_mut() {
            obj.insert(key.to_string(), value);
        }
        let new_settings: Settings = serde_json::from_value(v)?;
        *self = new_settings;
        self.normalize();
        Ok(())
    }
}
