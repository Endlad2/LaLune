// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Глобальное состояние демона: пути, настройки, конфиги, VPN runtime, events.

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

    /// SOCKS5-сервер для раздачи VPN (если share_vpn = true).
    pub socks5: Mutex<Option<tokio::task::JoinHandle<()>>>,

    shutdown: Notify,
}

/// Возвращает app_dir (для использования вне AppState).
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

impl AppState {
    pub async fn new() -> Result<Self> {
        let app_dir = app_dir()?;
        std::fs::create_dir_all(&app_dir)?;

        let configs_path = app_dir.join("configs.db");
        let settings_path = app_dir.join("settings.json");
        let logs_path = app_dir.join("logs.log");
        let token_path = app_dir.join("token.json");
        let core_path = app_dir.join(crate::core_manager::core_filename());

        // Загружаем или создаём настройки
        let mut settings = if settings_path.exists() {
            let data = std::fs::read_to_string(&settings_path)?;
            serde_json::from_str::<Settings>(&data).unwrap_or_default()
        } else {
            Settings::default()
        };
        settings.normalize();
        std::fs::write(&settings_path, serde_json::to_string_pretty(&settings)?)?;

        // Открываем SQLite
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
        // Останавливаем SOCKS5, если запущен.
        crate::socks5::stop(&Arc::new(self.clone_for_cleanup()));

        // Останавливаем VPN runtime (синхронно)
        self.vpn.stop();

        // Забираем процесс ядра из мьютекса (без await внутри lock).
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

    // Хак для cleanup: socks5::stop принимает &Arc<AppState>, а мы внутри
    // &self. Проще всего создать временный Arc и не париться.
    fn clone_for_cleanup(&self) -> AppState {
        // Нам нужен только доступ к self.socks5 и self.log — создаём
        // фиктивную структуру через mem::forget нельзя, поэтому просто
        // вынесем stop сюда явно.
        AppState {
            app_dir: self.app_dir.clone(),
            configs_path: self.configs_path.clone(),
            settings_path: self.settings_path.clone(),
            logs_path: self.logs_path.clone(),
            token_path: self.token_path.clone(),
            core_path: self.core_path.clone(),
            events: self.events.clone(),
            settings: RwLock::new(self.settings.read().clone()),
            selected_config: RwLock::new(self.selected_config.read().clone()),
            configs: self.configs.clone(),
            vpn: self.vpn.clone(),
            core: Mutex::new(None),
            logs: Mutex::new(Vec::new()),
            core_downloading: Mutex::new(false),
            deploy_busy: Mutex::new(false),
            deploy_log: Mutex::new(String::new()),
            smarttunnel_running: Mutex::new(false),
            socks5: Mutex::new(self.socks5.lock().take()),
            shutdown: Notify::new(),
        }
    }
}
