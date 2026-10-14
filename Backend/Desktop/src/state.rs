// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Глобальное состояние демона.

use anyhow::{anyhow, Result};
use parking_lot::{Mutex, RwLock};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Notify;

use crate::config::{ConfigItem, ConfigStore};
use crate::core_manager::CoreProcess;
use crate::events::EventBus;
use crate::settings::Settings;
use crate::vpn::VpnRuntime;

pub struct AppState {
    pub app_dir: PathBuf,
    pub configs_path: PathBuf,
    pub settings_path: PathBuf,
    pub logs_path: PathBuf,
    pub token_path: PathBuf,
    /// Путь к текущему запущенному ядру (csqtt или paperflux).
    /// Проставляется при connect.
    pub core_path: PathBuf,

    pub events: EventBus,
    pub settings: RwLock<Settings>,
    pub selected_config: RwLock<Option<ConfigItem>>,
    pub configs: ConfigStore,

    pub vpn: Arc<VpnRuntime>,
    pub core: Mutex<Option<CoreProcess>>,

    pub logs: Mutex<Vec<String>>,
    pub core_downloading: Mutex<bool>,
    pub deploy_busy: Mutex<bool>,
    pub deploy_log: Mutex<String>,
    pub smarttunnel_running: Mutex<bool>,

    pub socks5: Mutex<Option<tokio::task::JoinHandle<()>>>,

    shutdown: Notify,
}

pub fn app_dir() -> Result<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        let dir = dirs::data_dir()
            .ok_or_else(|| anyhow!("cannot resolve APPDATA"))?
            .join(".la-lune");
        Ok(dir)
    }
    #[cfg(not(target_os = "windows"))]
    {
        let dir = dirs::home_dir()
            .ok_or_else(|| anyhow!("cannot resolve HOME"))?
            .join(".la-lune");
        Ok(dir)
    }
}

/// Возвращает путь к ядру для указанного протокола.
pub fn core_path_for(app_dir: &PathBuf, protocol_id: &str) -> PathBuf {
    let kind = crate::protocol::ProtocolKind::from_id(protocol_id)
        .unwrap_or(crate::protocol::ProtocolKind::Csqtt);
    app_dir.join(kind.local_filename())
}

impl AppState {
    pub async fn new() -> Result<Self> {
        let app_dir = app_dir()?;
        std::fs::create_dir_all(&app_dir)?;

        let configs_path = app_dir.join("configs.db");
        let settings_path = app_dir.join("settings.json");
        let logs_path = app_dir.join("logs.log");
        let token_path = app_dir.join("token.json");
        // По умолчанию — CSQTT.
        let core_path = core_path_for(&app_dir, "CSQTT");

        let mut settings = if settings_path.exists() {
            let data = std::fs::read_to_string(&settings_path)?;
            serde_json::from_str::<Settings>(&data).unwrap_or_default()
        } else {
            Settings::default()
        };
        settings.normalize();
        std::fs::write(&settings_path, serde_json::to_string_pretty(&settings)?)?;

        let configs = ConfigStore::open(&configs_path)?;
        let events = EventBus::new(1024);

        events.emit(crate::events::Event::log(format!(
            "[INFO] app dir: {}",
            app_dir.display()
        )));

        Ok(Self {
            app_dir,
            configs_path,
            settings_path,
            logs_path,
            token_path,
            core_path,
            events,
            settings: RwLock::new(settings),
            selected_config: RwLock::new(None),
            configs,
            vpn: Arc::new(VpnRuntime::new()),
            core: Mutex::new(None),
            logs: Mutex::new(Vec::new()),
            core_downloading: Mutex::new(false),
            deploy_busy: Mutex::new(false),
            deploy_log: Mutex::new(String::new()),
            smarttunnel_running: Mutex::new(false),
            socks5: Mutex::new(None),
            shutdown: Notify::new(),
        })
    }

    pub fn log(&self, line: impl Into<String>) {
        let line = line.into();
        log::info!("{}", line);
        let mut logs = self.logs.lock();
        logs.push(line.clone());
        if logs.len() > 1000 {
            let drain = logs.len() - 1000;
            logs.drain(..drain);
        }
        drop(logs);
        self.events.emit(crate::events::Event::log(line));
    }

    pub fn save_settings(&self) -> Result<()> {
        let s = self.settings.read().clone();
        std::fs::write(&self.settings_path, serde_json::to_string_pretty(&s)?)?;
        Ok(())
    }

    pub fn logs_snapshot(&self) -> Vec<String> {
        self.logs.lock().clone()
    }

    pub async fn maybe_autostart_smarttunnel(&self) {
        let enabled = self.settings.read().enable_smart_tunnel;
        if enabled {
            *self.smarttunnel_running.lock() = true;
            self.log("[SMART-TUNNEL] auto-started");
        }
    }

    pub fn notify_shutdown(&self) {
        self.shutdown.notify_waiters();
    }

    pub async fn shutdown_notified(&self) {
        self.shutdown.notified().await;
    }

    pub async fn cleanup(&self) {
        // SOCKS5
        {
            let handle = { self.socks5.lock().take() };
            if let Some(h) = handle { h.abort(); }
        }

        // VPN
        self.vpn.stop();

        // Core
        let maybe_proc = {
            let mut core = self.core.lock();
            core.take()
        };
        if let Some(mut p) = maybe_proc {
            let _ = p.kill().await;
        }
    }

    pub fn uptime(&self) -> u64 {
        0
    }
}
