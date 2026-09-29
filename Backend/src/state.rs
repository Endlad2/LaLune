//! AppState — единое состояние приложения.

use std::collections::VecDeque;
use std::process::Child;
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

use crate::{
    app_dir, config, configs_db_path, core_path, core_runner, deploy, latest_path, logs_path,
    settings as settings_mod, settings_path, token as token_mod, token_path, vk_api, vk_launcher,
};

const LOG_LIMIT: usize = 500;
const LALUNE_VERSION: &str = "0.6.0";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub id: i64,
    #[serde(default = "default_protocol")]
    pub protocol: String,
    #[serde(default)]
    pub peer: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub hashes: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "rawLink")]
    pub raw_link: String,
}

fn default_protocol() -> String { "CSQTT".into() }

pub struct AppState {
    initialized: bool,
    logs: VecDeque<String>,
    settings: settings_mod::Settings,
    selected_config: Option<Config>,
    connected: bool,
    core_process: Option<Child>,
    core_downloading: bool,
    token: Option<token_mod::VkToken>,
    deploy_log: String,
    deploying: bool,
    vk_call_ids: Vec<String>,
    vk_login_in_progress: bool,
    // shared handle для tail-core-log-thread
    self_arc: Option<Arc<Mutex<AppState>>>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            initialized: false,
            logs: VecDeque::with_capacity(LOG_LIMIT),
            settings: settings_mod::Settings::default(),
            selected_config: None,
            connected: false,
            core_process: None,
            core_downloading: false,
            token: None,
            deploy_log: String::new(),
            deploying: false,
            vk_call_ids: Vec::new(),
            vk_login_in_progress: false,
            self_arc: None,
        }
    }

    /// Устанавливается один раз из lib.rs, чтобы core_runner мог логировать.
    pub fn set_self_arc(&mut self, arc: Arc<Mutex<AppState>>) {
        self.self_arc = Some(arc);
    }

    pub fn init(&mut self) -> Result<()> {
        if self.initialized { return Ok(()); }
        std::fs::create_dir_all(app_dir())?;

        config::open_db(&configs_db_path())?;
        self.settings = settings_mod::load_settings(&settings_path())?;
        self.token = token_mod::load_token(&token_path()).ok();

        self.log("[INIT] LaLune backend готов");
        self.log(format!("[INIT] каталог: {}", app_dir().display()));
        self.initialized = true;
        Ok(())
    }

    pub fn log<S: Into<String>>(&mut self, line: S) {
        let line = line.into();
        println!("{line}");
        if self.logs.len() >= LOG_LIMIT { self.logs.pop_front(); }
        self.logs.push_back(line.clone());
        let _ = std::fs::OpenOptions::new()
            .create(true).append(true)
            .open(logs_path())
            .and_then(|mut f| {
                use std::io::Write;
                writeln!(f, "{line}")
            });
    }

    // -------------------- Configs --------------------

    pub fn get_configs_json(&self) -> String {
        match config::load_configs() {
            Ok(v) => serde_json::to_string(&v).unwrap_or_else(|_| "[]".into()),
            Err(_) => "[]".into(),
        }
    }

    pub fn save_config(&mut self, link: &str, protocol: &str) -> Result<()> {
        let cfg = config::parse_link(link, protocol);
        config::insert_config(&cfg)?;
        self.log(format!("[CONFIG] сохранён: {} ({})", cfg.peer, cfg.protocol));
        Ok(())
    }

    pub fn delete_config(&mut self, id: i64) -> Result<()> {
        config::delete_config(id)?;
        self.log(format!("[CONFIG] удалён id={id}"));
        Ok(())
    }

    // -------------------- Settings --------------------

    pub fn get_settings_json(&self) -> String {
        serde_json::to_string(&self.settings).unwrap_or_else(|_| "{}".into())
    }

    pub fn save_settings(&mut self, json: &str) -> Result<()> {
        let mut s: settings_mod::Settings = serde_json::from_str(json)?;
        settings_mod::clamp(&mut s);
        if s.device_id.is_empty() { s.device_id = self.settings.device_id.clone(); }
        if s.device_id.is_empty() { s.device_id = settings_mod::new_device_id(); }
        settings_mod::save_settings(&settings_path(), &s)?;
        self.settings = s;
        self.log("[SETTINGS] сохранены");
        Ok(())
    }

    // -------------------- Logs --------------------

    pub fn get_logs_json(&self) -> String {
        let v: Vec<&String> = self.logs.iter().collect();
        serde_json::to_string(&v).unwrap_or_else(|_| "[]".into())
    }

    pub fn clear_logs(&mut self) {
        self.logs.clear();
        let _ = std::fs::write(logs_path(), "");
    }

    // -------------------- Device ID --------------------

    pub fn get_device_id(&self) -> String { self.settings.device_id.clone() }

    pub fn regenerate_device_id(&mut self) -> String {
        let id = settings_mod::new_device_id();
        self.settings.device_id = id.clone();
        let _ = settings_mod::save_settings(&settings_path(), &self.settings);
        self.log(format!("[DEVICE] новый id={id}"));
        id
    }

    // -------------------- Selected config --------------------

    pub fn set_selected_config_json(&mut self, json: &str) {
        match serde_json::from_str::<Config>(json) {
            Ok(c) => self.selected_config = Some(c),
            Err(_) => self.selected_config = None,
        }
    }

    pub fn get_selected_config_json(&self) -> String {
        match &self.selected_config {
            Some(c) => serde_json::to_string(c).unwrap_or_else(|_| "{}".into()),
            None => "{}".into(),
        }
    }

    // -------------------- Connect / Disconnect --------------------

    pub fn is_connected(&self) -> bool { self.connected }
    pub fn is_core_downloading(&self) -> bool { self.core_downloading }

    pub fn connect(&mut self, config_id: i64) -> Result<()> {
        let cfg = config::get_config(config_id)?
            .ok_or_else(|| anyhow!("config {config_id} не найден"))?;
        self.selected_config = Some(cfg.clone());

        if !core_path().exists() {
            self.log("[CORE] ядро не найдено, скачиваю...");
            self.core_downloading = true;
            let r = core_runner::download_core(&mut self.logs);
            self.core_downloading = false;
            r?;
        }

        self.log(format!("[CONNECT] {} (peer={})", cfg.name, cfg.peer));
        let child = core_runner::spawn_core(&cfg, &self.settings, &mut self.logs)?;
        self.core_process = Some(child);
        self.connected = true;

        // Запускаем tail-поток — он льёт stdout ядра в логи приложения.
        if let Some(arc) = self.self_arc.clone() {
            core_runner::tail_core_log_into(arc);
        }

        Ok(())
    }

    pub fn disconnect(&mut self) -> Result<()> {
        if let Some(mut c) = self.core_process.take() {
            let _ = c.kill();
        }
        self.connected = false;
        self.log("[DISCONNECT] ядро остановлено");
        Ok(())
    }

    // -------------------- VK --------------------

    pub fn get_vk_token_state_json(&self) -> String {
        let has_file = token_path().exists();
        let has_in_mem = self.token.as_ref().map(|t| !t.token.is_empty()).unwrap_or(false);
        let has = has_in_mem || has_file;
        serde_json::json!({
            "hasToken": has,
            "fetcherOk": true,
            "fetching": self.vk_login_in_progress,
            "message": if has { "Токен ВК активен" } else { "" },
            "progress": if has { 100 } else if self.vk_login_in_progress { 50 } else { 0 },
        }).to_string()
    }

    pub fn vk_login(&mut self) -> Result<()> {
        if self.vk_login_in_progress {
            return Err(anyhow!("логин уже идёт"));
        }
        self.vk_login_in_progress = true;
        self.log("[VK] старт логина");

        match vk_launcher::start_fetcher(&mut self.logs) {
            Ok(()) => Ok(()),
            Err(e) => {
                self.vk_login_in_progress = false;
                Err(e)
            }
        }
    }

    pub fn delete_vk_token(&mut self) {
        let _ = std::fs::remove_file(token_path());
        self.token = None;
        self.log("[VK] токен удалён");
    }

    pub fn run_vk_auto_api_calls(&mut self) -> String {
        let token = match token_mod::load_token(&token_path()) {
            Ok(t) if !t.token.is_empty() => t.token,
            _ => return serde_json::json!({"error": "токен ВК не найден"}).to_string(),
        };
        let workers = self.settings.workers;
        let aw = self.settings.auto_api_workers;
        match vk_api::create_calls(&token, workers, aw, &mut self.logs) {
            Ok((hashes, call_ids)) => {
                self.vk_call_ids = call_ids.clone();
                serde_json::json!({"hashes": hashes, "callIds": call_ids}).to_string()
            }
            Err(e) => serde_json::json!({"error": e.to_string()}).to_string(),
        }
    }

    // -------------------- Updates --------------------

    pub fn check_core_update_json(&mut self) -> String {
        match core_runner::fetch_latest(&mut self.logs) {
            Some(remote) => {
                let local = std::fs::read_to_string(latest_path()).unwrap_or_default();
                let local = local.trim().to_string();
                let has = !remote.is_empty() && remote != local;
                serde_json::json!({"update": has, "version": remote}).to_string()
            }
            None => serde_json::json!({"update": false, "version": ""}).to_string(),
        }
    }

    pub fn check_lalune_update_json(&mut self) -> String {
        serde_json::json!({"update": false, "version": LALUNE_VERSION}).to_string()
    }

    pub fn update_core_and_wait(&mut self) -> Result<()> {
        if self.connected {
            let _ = self.disconnect();
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
        self.core_downloading = true;
        let r = core_runner::download_core(&mut self.logs);
        self.core_downloading = false;
        r
    }

    // -------------------- Deploy --------------------

    pub fn deploy_protocol(&mut self, req_json: &str) -> Result<()> {
        if self.deploying { return Err(anyhow!("deploy уже идёт")); }
        self.deploy_log.clear();
        self.deploying = true;
        let log_line = deploy::run_deploy(req_json, &mut self.logs)?;
        self.deploy_log = log_line;
        self.deploying = false;
        Ok(())
    }

    pub fn deploy_log(&self) -> String { self.deploy_log.clone() }
    pub fn is_deploying(&self) -> bool { self.deploying }
}
