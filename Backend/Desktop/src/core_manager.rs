// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Ядро: скачивание, запуск, URL-ассеты.
//
// FreeTurn больше не запускается как отдельный бинарь: Desktop-бэкенд
// запускает `freeturn-core` (client) в режиме relay-only, а TUN мостит
// сам (Wintun / tun crate). Это тот же `client`, что и на Android,
// но собранный под хост.

use anyhow::{anyhow, Result};
use std::path::Path;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use crate::events::{Event, EventBus};

pub const LATEST_CSQTT_URL: &str = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST";
pub const LATEST_PAPERFLUX_URL: &str = "https://raw.githubusercontent.com/Endlad2/PaperFlux-core/refs/heads/main/LATEST";

pub const CSQTT_URL_TEMPLATE: &str = "https://github.com/Endlad2/csqtt-core/releases/download/{VER}/{FILE}";
pub const PAPERFLUX_URL_TEMPLATE: &str = "https://github.com/Endlad2/PaperFlux-core/releases/latest/download/{FILE}";

// FreeTurn upstream (hackdiaz-dev/free-turn-proxy) — релизные ассеты:
//   client-<os>-<arch>    — CLI-клиент, годится как relay-only процесс.
//   client-<os>-<arch>    — сервер, нам не нужен.
// LATEST у них нет (release-please), поэтому качаем latest.
pub const FREETURN_URL_TEMPLATE: &str = "https://github.com/hackdiaz-dev/free-turn-proxy/releases/latest/download/{FILE}";

pub const PROXY_URL: &str = "http://31.77.148.203:8855/?url=";
pub const USER_AGENT_BROWSER: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
pub const USER_AGENT_CURL: &str = "curl/7.68.0";

pub fn csqtt_asset_name() -> &'static str {
    #[cfg(target_os = "windows")] { "client-windows-x86_64.exe" }
    #[cfg(target_os = "linux")] { "client-linux-x86_64" }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))] { "client-unknown" }
}

pub fn csqtt_local_filename() -> &'static str {
    #[cfg(target_os = "windows")] { "csqtt-core.exe" }
    #[cfg(not(target_os = "windows"))] { "csqtt-core" }
}

pub fn paperflux_asset_name() -> &'static str {
    #[cfg(target_os = "windows")] { "paperflux-windows-amd64.exe" }
    #[cfg(target_os = "linux")] { "paperflux-linux-amd64" }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))] { "paperflux-unknown" }
}

pub fn paperflux_local_filename() -> &'static str {
    #[cfg(target_os = "windows")] { "paperflux-core.exe" }
    #[cfg(not(target_os = "windows"))] { "paperflux-core" }
}

pub fn freeturn_asset_name() -> &'static str {
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))] { "client-windows-amd64.exe" }
    #[cfg(all(target_os = "windows", target_arch = "aarch64"))] { "client-windows-arm64.exe" }
    #[cfg(all(target_os = "windows", target_arch = "x86"))] { "client-windows-386.exe" }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))] { "client-linux-amd64" }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))] { "client-linux-arm64" }
    #[cfg(all(target_os = "linux", target_arch = "arm"))] { "client-linux-armv7" }
    #[cfg(not(any(
        target_os = "windows",
        target_os = "linux",
    )))] { "client-unknown" }
}

pub fn freeturn_local_filename() -> &'static str {
    #[cfg(target_os = "windows")] { "freeturn-core.exe" }
    #[cfg(not(target_os = "windows"))] { "freeturn-core" }
}

pub fn supported_protocols() -> Vec<serde_json::Value> {
    crate::protocol::supported_protocols()
}

pub async fn fetch_latest_csqtt(client: &reqwest::Client, events: &EventBus) -> Option<String> {
    fetch_latest_generic(client, events, LATEST_CSQTT_URL).await
}

pub async fn fetch_latest_paperflux(client: &reqwest::Client, events: &EventBus) -> Option<String> {
    fetch_latest_generic(client, events, LATEST_PAPERFLUX_URL).await
}

async fn fetch_latest_generic(client: &reqwest::Client, events: &EventBus, base_url: &str) -> Option<String> {
    let urls = [
        base_url.to_string(),
        format!("{}{}", PROXY_URL, urlencode(base_url)),
        format!("{}{}", PROXY_URL, urlencode(base_url)),
    ];

    for (i, url) in urls.iter().enumerate() {
        let level = i + 1;
        let ua = if level == 3 { USER_AGENT_CURL } else { USER_AGENT_BROWSER };
        events.emit(Event::log(format!("[NET][LEVEL {}] Fetching LATEST: {}", level, truncate(url, 100))));
        let resp = match client.get(url).header("User-Agent", ua).send().await { Ok(r) => r, Err(_) => continue };
        if resp.status().as_u16() != 200 { continue; }
        let text = match resp.text().await { Ok(t) => t, Err(_) => continue };
        let version = text.trim().to_string();
        if !version.is_empty() && !version.contains("Server error") {
            return Some(version);
        }
    }
    None
}

pub async fn download_csqtt(client: &reqwest::Client, version: &str, dest: &Path, events: &EventBus) -> Result<()> {
    let url = CSQTT_URL_TEMPLATE.replace("{VER}", version).replace("{FILE}", csqtt_asset_name());
    download_binary(client, &url, dest, events).await
}

pub async fn download_paperflux(client: &reqwest::Client, dest: &Path, events: &EventBus) -> Result<()> {
    let url = PAPERFLUX_URL_TEMPLATE.replace("{FILE}", paperflux_asset_name());
    download_binary(client, &url, dest, events).await
}

pub async fn download_freeturn(client: &reqwest::Client, dest: &Path, events: &EventBus) -> Result<()> {
    let url = FREETURN_URL_TEMPLATE.replace("{FILE}", freeturn_asset_name());
    download_binary(client, &url, dest, events).await
}

async fn download_binary(client: &reqwest::Client, base_url: &str, dest: &Path, events: &EventBus) -> Result<()> {
    let urls = [
        base_url.to_string(),
        format!("{}{}", PROXY_URL, urlencode(base_url)),
        format!("{}{}", PROXY_URL, urlencode(base_url)),
    ];

    for (i, url) in urls.iter().enumerate() {
        let level = i + 1;
        let ua = if level == 3 { USER_AGENT_CURL } else { USER_AGENT_BROWSER };
        events.emit(Event::log(format!("[DOWNLOAD][LEVEL {}] {}", level, truncate(url, 120))));
        let resp = match client.get(url).header("User-Agent", ua).send().await { Ok(r) => r, Err(_) => continue };
        if resp.status().as_u16() != 200 { continue; }
        let bytes = match resp.bytes().await { Ok(b) => b, Err(_) => continue };
        if bytes.len() < 1024 { continue; }

        let tmp = dest.with_extension("tmp");
        if let Some(parent) = tmp.parent() { tokio::fs::create_dir_all(parent).await.ok(); }
        let mut f = tokio::fs::File::create(&tmp).await?;
        f.write_all(&bytes).await?;
        f.flush().await?;
        drop(f);

        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = tokio::fs::metadata(&tmp).await?.permissions();
            perms.set_mode(0o755);
            tokio::fs::set_permissions(&tmp, perms).await?;
        }

        if dest.exists() { let _ = tokio::fs::remove_file(dest).await; }
        tokio::fs::rename(&tmp, dest).await?;
        return Ok(());
    }
    Err(anyhow!("failed to download after 3 attempts: {}", base_url))
}

fn urlencode(s: &str) -> String {
    s.replace('%', "%25").replace(':', "%3A").replace('/', "%2F").replace('?', "%3F").replace('&', "%26").replace('=', "%3D")
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max { s.to_string() } else { format!("{}...", &s[..max]) }
}

pub struct CoreProcess { pub child: Child }

impl CoreProcess {
    pub async fn spawn(core_path: &Path, args: &[String], log_file: &Path, events: EventBus) -> Result<Self> {
        let log = std::fs::File::create(log_file)?;
        let mut cmd = Command::new(core_path);
        cmd.args(args);
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn()?;
        events.emit(Event::log(format!("[CORE] spawned pid={:?}", child.id())));

        if let Some(stdout) = child.stdout.take() {
            let log_path = log_file.to_path_buf();
            let events_out = events.clone();
            tokio::spawn(async move {
                let mut reader = BufReader::new(stdout).lines();
                let mut file = tokio::fs::OpenOptions::new().create(true).append(true).open(&log_path).await.ok();
                while let Ok(Some(line)) = reader.next_line().await {
                    if let Some(f) = file.as_mut() {
                        let _ = f.write_all(line.as_bytes()).await;
                        let _ = f.write_all(b"\n").await;
                        let _ = f.flush().await;
                    }
                    events_out.emit(Event::log(format!("[CORE] {}", line)));
                }
            });
        }
        if let Some(stderr) = child.stderr.take() {
            let log_path = log_file.to_path_buf();
            let events_err = events.clone();
            tokio::spawn(async move {
                let mut reader = BufReader::new(stderr).lines();
                let mut file = tokio::fs::OpenOptions::new().create(true).append(true).open(&log_path).await.ok();
                while let Ok(Some(line)) = reader.next_line().await {
                    if let Some(f) = file.as_mut() {
                        let _ = f.write_all(line.as_bytes()).await;
                        let _ = f.write_all(b"\n").await;
                        let _ = f.flush().await;
                    }
                    events_err.emit(Event::log(format!("[CORE] {}", line)));
                }
            });
        }
        drop(log);
        Ok(Self { child })
    }
    pub async fn kill(&mut self) -> Result<()> { self.child.kill().await?; Ok(()) }
}

pub fn build_args(config: &crate::config::ConfigItem, settings: &crate::settings::Settings, listen_port: u16) -> Vec<String> {
    crate::protocol::build_args(config, settings, listen_port)
}
