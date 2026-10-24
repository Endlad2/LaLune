// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Ядро: CSQTT + PaperFlux. Трёхуровневый fallback (direct / proxy-browserUA / proxy-curlUA).
//
// stdout/stderr читаются построчно, эмитятся с префиксом [CORE]
// и параллельно пишутся в logs.log (для watchdog'а).

use anyhow::{anyhow, Result};
use std::path::Path;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};

use crate::events::{Event, EventBus};

pub const LATEST_CSQTT_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST";
pub const LATEST_PAPERFLUX_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/PaperFlux-core/refs/heads/main/LATEST";

pub const CSQTT_URL_TEMPLATE: &str =
    "https://github.com/Endlad2/csqtt-core/releases/download/{VER}/{FILE}";
pub const CSQTT_219_RELEASE: &str = "2026.09.17.17.36";
pub const PAPERFLUX_URL_TEMPLATE: &str =
    "https://github.com/Endlad2/PaperFlux-core/releases/latest/download/{FILE}";

pub const PROXY_URL: &str = "http://31.77.148.203:8855/?url=";
pub const USER_AGENT_BROWSER: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
pub const USER_AGENT_CURL: &str = "curl/7.68.0";

// ============================================================
//  CSQTT: имена ассетов
// ============================================================

pub fn csqtt_asset_name() -> &'static str {
    #[cfg(target_os = "windows")]
    { "client-windows-x86_64.exe" }
    #[cfg(target_os = "linux")]
    { "client-linux-x86_64" }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    { "client-unknown" }
}

pub fn csqtt_local_filename() -> &'static str {
    #[cfg(target_os = "windows")]
    { "csqtt-core.exe" }
    #[cfg(not(target_os = "windows"))]
    { "csqtt-core" }
}

// ============================================================
//  PaperFlux: имена ассетов
// ============================================================

pub fn paperflux_asset_name() -> &'static str {
    #[cfg(target_os = "windows")]
    { "paperflux-windows-amd64.exe" }
    #[cfg(target_os = "linux")]
    { "paperflux-linux-amd64" }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    { "paperflux-unknown" }
}

pub fn paperflux_local_filename() -> &'static str {
    #[cfg(target_os = "windows")]
    { "paperflux-core.exe" }
    #[cfg(not(target_os = "windows"))]
    { "paperflux-core" }
}

/// Список поддерживаемых протоколов (делегируем в protocol.rs).
pub fn supported_protocols() -> Vec<serde_json::Value> {
    crate::protocol::supported_protocols()
}

// ============================================================
//  fetch_latest / download — общие, per-protocol
// ============================================================

/// Скачивает LATEST для CSQTT.
pub async fn fetch_latest_csqtt(client: &reqwest::Client, events: &EventBus) -> Option<String> {
    fetch_latest_generic(client, events, LATEST_CSQTT_URL).await
}

/// Скачивает LATEST для PaperFlux.
pub async fn fetch_latest_paperflux(client: &reqwest::Client, events: &EventBus) -> Option<String> {
    fetch_latest_generic(client, events, LATEST_PAPERFLUX_URL).await
}

async fn fetch_latest_generic(
    client: &reqwest::Client,
    events: &EventBus,
    base_url: &str,
) -> Option<String> {
    let urls = [
        base_url.to_string(),
        format!("{}{}", PROXY_URL, urlencode(base_url)),
        format!("{}{}", PROXY_URL, urlencode(base_url)),
    ];

    for (i, url) in urls.iter().enumerate() {
        let level = i + 1;
        let ua = if level == 3 { USER_AGENT_CURL } else { USER_AGENT_BROWSER };

        events.emit(Event::log(format!(
            "[NET][LEVEL {}] Fetching LATEST: {}", level, truncate(url, 100)
        )));

        let resp = match client.get(url).header("User-Agent", ua).send().await {
            Ok(r) => r,
            Err(e) => {
                events.emit(Event::log(format!("[NET][LEVEL {}] error: {}", level, e)));
                continue;
            }
        };

        if resp.status().as_u16() != 200 {
            events.emit(Event::log(format!("[NET][LEVEL {}] HTTP {}", level, resp.status())));
            continue;
        }

        let text = match resp.text().await { Ok(t) => t, Err(_) => continue };

        let version: String = text
            .chars()
            .filter(|c| *c != '\n' && *c != '\r')
            .collect::<String>()
            .trim()
            .to_string();

        if version.is_empty()
            || version.contains("Server error")
            || version.contains("No connection adapters")
            || version.contains("curl error")
        {
            events.emit(Event::log(format!("[NET][LEVEL {}] server error payload", level)));
            continue;
        }

        events.emit(Event::log(format!("[NET][LEVEL {}] LATEST = {}", level, version)));
        return Some(version);
    }
    None
}

/// Скачивает и кладёт ядро CSQTT.
pub async fn download_csqtt(
    client: &reqwest::Client,
    version: &str,
    dest: &Path,
    events: &EventBus,
) -> Result<()> {
    let file = csqtt_asset_name();
    let url = CSQTT_URL_TEMPLATE
        .replace("{VER}", version)
        .replace("{FILE}", file);
    download_binary(client, &url, dest, events).await
}

/// Скачивает CSQTT 2.1.9 строго из закреплённого релиза.
pub async fn download_csqtt_219(
    client: &reqwest::Client,
    dest: &Path,
    events: &EventBus,
) -> Result<()> {
    let url = CSQTT_URL_TEMPLATE
        .replace("{VER}", CSQTT_219_RELEASE)
        .replace("{FILE}", csqtt_asset_name());
    download_binary(client, &url, dest, events).await
}

/// Скачивает и кладёт ядро PaperFlux (latest).
pub async fn download_paperflux(
    client: &reqwest::Client,
    dest: &Path,
    events: &EventBus,
) -> Result<()> {
    let file = paperflux_asset_name();
    let url = PAPERFLUX_URL_TEMPLATE.replace("{FILE}", file);
    download_binary(client, &url, dest, events).await
}

async fn download_binary(
    client: &reqwest::Client,
    base_url: &str,
    dest: &Path,
    events: &EventBus,
) -> Result<()> {
    let urls = [
        base_url.to_string(),
        format!("{}{}", PROXY_URL, urlencode(base_url)),
        format!("{}{}", PROXY_URL, urlencode(base_url)),
    ];

    for (i, url) in urls.iter().enumerate() {
        let level = i + 1;
        let ua = if level == 3 { USER_AGENT_CURL } else { USER_AGENT_BROWSER };

        events.emit(Event::log(format!("[DOWNLOAD][LEVEL {}] {}", level, truncate(url, 120))));

        let resp = match client.get(url).header("User-Agent", ua).send().await {
            Ok(r) => r, Err(_) => continue,
        };
        if resp.status().as_u16() != 200 { continue; }
        let bytes = match resp.bytes().await { Ok(b) => b, Err(_) => continue };
        if bytes.len() < 1024 {
            events.emit(Event::log(format!(
                "[DOWNLOAD][LEVEL {}] too small ({} bytes)", level, bytes.len()
            )));
            continue;
        }

        let tmp = dest.with_extension("tmp");
        if let Some(parent) = tmp.parent() {
            tokio::fs::create_dir_all(parent).await.ok();
        }
        let mut f = tokio::fs::File::create(&tmp).await?;
        f.write_all(&bytes).await?;
        f.flush().await?;
        drop(f);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = tokio::fs::metadata(&tmp).await?.permissions();
            perms.set_mode(0o755);
            tokio::fs::set_permissions(&tmp, perms).await?;
        }

        if dest.exists() { let _ = tokio::fs::remove_file(dest).await; }
        tokio::fs::rename(&tmp, dest).await?;

        events.emit(Event::log(format!(
            "[DOWNLOAD][LEVEL {}] OK ({} bytes) → {}", level, bytes.len(), dest.display()
        )));
        return Ok(());
    }
    Err(anyhow!("failed to download after 3 attempts: {}", base_url))
}

fn urlencode(s: &str) -> String {
    s.replace('%', "%25")
        .replace(':', "%3A")
        .replace('/', "%2F")
        .replace('?', "%3F")
        .replace('&', "%26")
        .replace('=', "%3D")
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max { s.to_string() } else { format!("{}...", &s[..max]) }
}

// ============================================================
//  CoreProcess
// ============================================================

pub struct CoreProcess {
    pub child: Child,
}

impl CoreProcess {
    pub async fn spawn(
        core_path: &Path,
        args: &[String],
        log_file: &Path,
        events: EventBus,
    ) -> Result<Self> {
        let log = std::fs::File::create(log_file)?;
        let log_err = log.try_clone()?;

        let mut cmd = Command::new(core_path);
        cmd.args(args);

        cmd.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let mut child = cmd.spawn()?;
        let pid = child.id();

        events.emit(Event::log(format!("[CORE] spawned pid={:?}", pid)));

        // --- stdout reader ---
        if let Some(stdout) = child.stdout.take() {
            let log_path = log_file.to_path_buf();
            let events_out = events.clone();
            tokio::spawn(async move {
                let mut reader = BufReader::new(stdout).lines();
                let mut file = tokio::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&log_path)
                    .await
                    .ok();

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

        // --- stderr reader ---
        if let Some(stderr) = child.stderr.take() {
            let log_path = log_file.to_path_buf();
            let events_err = events.clone();
            tokio::spawn(async move {
                let mut reader = BufReader::new(stderr).lines();
                let mut file = tokio::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&log_path)
                    .await
                    .ok();

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
        drop(log_err);

        Ok(Self { child })
    }

    pub async fn kill(&mut self) -> Result<()> {
        self.child.kill().await?;
        Ok(())
    }
}

/// Собирает аргументы для запуска ядра. Делегируем в protocol.rs,
/// чтобы не дублировать логику.
pub fn build_args(
    config: &crate::config::ConfigItem,
    settings: &crate::settings::Settings,
    listen_port: u16,
) -> Vec<String> {
    crate::protocol::build_args(config, settings, listen_port)
}
