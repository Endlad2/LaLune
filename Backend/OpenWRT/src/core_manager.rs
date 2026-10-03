// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Ядро CSQTT на OpenWRT.
//
// Отличие от Desktop: имя бинарника фиксировано —
// ~/.la-lune/csqtt-client-aarch64
//
// stdout/stderr читаются построчно, эмитятся с префиксом [CORE]
// (чтобы UI видел их на вкладке Логи) и параллельно пишутся в logs.log.

use anyhow::{anyhow, Result};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};

use crate::events::{Event, EventBus};

pub const LATEST_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST";
pub const CORE_URL_TEMPLATE: &str =
    "https://github.com/Endlad2/csqtt-core/releases/download/{VER}/{FILE}";
pub const PROXY_URL: &str = "http://31.77.148.203:8855/?url=";
pub const USER_AGENT_BROWSER: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
pub const USER_AGENT_CURL: &str = "curl/7.68.0";

/// На OpenWRT имя ядра фиксировано — `csqtt-client-aarch64`.
pub fn core_filename() -> &'static str {
    "csqtt-client-aarch64"
}

/// Имя ассета в GitHub Releases (совпадает с Download URL).
pub fn core_asset_name() -> &'static str {
    "client-linux-arm64"
}

pub fn supported_protocols() -> Vec<serde_json::Value> {
    vec![
        serde_json::json!({
            "id": "CSQTT",
            "displayName": "CSQTT (VK Calls)",
            "repo": "Endlad2/csqtt-core",
            "realtime": true,
            "description": "Оригинальный протокол на базе VK Calls, TURN и WRAP.",
            "coreAsset": core_asset_name(),
        }),
    ]
}

pub async fn fetch_latest(client: &reqwest::Client, events: &EventBus) -> Option<String> {
    let urls = [
        LATEST_URL.to_string(),
        format!("{}{}", PROXY_URL, urlencode(LATEST_URL)),
        format!("{}{}", PROXY_URL, urlencode(LATEST_URL)),
    ];

    for (i, url) in urls.iter().enumerate() {
        let level = i + 1;
        let ua = if level == 3 { USER_AGENT_CURL } else { USER_AGENT_BROWSER };

        events.emit(Event::log(format!("[NET][LEVEL {}] LATEST: {}", level, truncate(url, 100))));

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

        let version: String = text.chars().filter(|c| *c != '\n' && *c != '\r').collect::<String>().trim().to_string();

        if version.is_empty()
            || version.contains("Server error")
            || version.contains("No connection adapters")
            || version.contains("curl error")
        {
            continue;
        }

        events.emit(Event::log(format!("[NET][LEVEL {}] LATEST = {}", level, version)));
        return Some(version);
    }

    None
}

pub async fn download_core(
    client: &reqwest::Client,
    version: &str,
    dest: &Path,
    events: &EventBus,
) -> Result<()> {
    let file = core_asset_name();
    let base_url = CORE_URL_TEMPLATE.replace("{VER}", version).replace("{FILE}", file);

    let urls = [
        base_url.clone(),
        format!("{}{}", PROXY_URL, urlencode(&base_url)),
        format!("{}{}", PROXY_URL, urlencode(&base_url)),
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

        if bytes.len() < 1024 { continue; }

        let tmp = dest.with_extension("tmp");
        if let Some(parent) = tmp.parent() { tokio::fs::create_dir_all(parent).await.ok(); }
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

        events.emit(Event::log(format!("[DOWNLOAD][LEVEL {}] OK ({} bytes)", level, bytes.len())));
        return Ok(());
    }

    Err(anyhow!("failed to download core after 3 attempts"))
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

pub struct CoreProcess { pub child: Child }

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
        events.emit(Event::log(format!("[CORE] spawned pid={:?}", child.id())));

        if let Some(stdout) = child.stdout.take() {
            let log_path = log_file.to_path_buf();
            let events_out = events.clone();
            tokio::spawn(async move {
                let mut reader = BufReader::new(stdout).lines();
                let mut file = tokio::fs::OpenOptions::new()
                    .create(true).append(true).open(&log_path).await.ok();
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
                let mut file = tokio::fs::OpenOptions::new()
                    .create(true).append(true).open(&log_path).await.ok();
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

pub fn build_args(
    config: &crate::config::ConfigItem,
    settings: &crate::settings::Settings,
    listen_port: u16,
) -> Vec<String> {
    let normalized = config.hashes.replace([' ', '\t', '\n', '\r'], ",");
    let clean: Vec<String> = normalized.split(',').map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty()).take(6).collect();

    let hashes = if clean.is_empty() { String::new() } else { clean.join(",") };

    let auth_mode = if settings.auth_mode.is_empty() { "manual".to_string() } else { settings.auth_mode.clone() };
    let is_auto_vk = auth_mode == "autoVk";

    let hash_mode = if is_auto_vk { "auto_js" } else { "manual" };
    let vk_auth_mode = if is_auto_vk { "auto_js" }
        else if settings.vk_auth_mode.is_empty() { "vkcalls" }
        else { &settings.vk_auth_mode };

    let workers = settings.workers.clamp(crate::settings::MIN_WORKERS, crate::settings::MAX_WORKERS);

    let mut args: Vec<String> = vec![
        "--peer".into(), config.peer.clone(),
        "--password".into(), config.password.clone(),
        "--vk-hash-mode".into(), hash_mode.into(),
        "--vk-auth-mode".into(), vk_auth_mode.into(),
        "--listen".into(), format!("127.0.0.1:{}", listen_port),
        "-n".into(), workers.to_string(),
        "--obfs".into(), settings.obfs.clone(),
        "--fingerprint".into(), settings.fingerprint.clone(),
        "--client-ids".into(), settings.client_ids.clone(),
        "--captcha-mode".into(), settings.captcha_mode.clone(),
        "--turn-transport".into(), settings.turn_transport.clone(),
        "--device-id".into(), settings.device_id.clone(),
    ];

    if !is_auto_vk {
        args.push("--vk".into());
        args.push(hashes);
    }

    if is_auto_vk {
        if let Some(token) = read_token_for_core() {
            args.push("--token".into());
            args.push(token);
        }
    }

    if !settings.turn_host.is_empty() {
        args.push("--turn".into());
        args.push(settings.turn_host.clone());
    }
    if !settings.turn_port.is_empty() {
        args.push("--port".into());
        args.push(settings.turn_port.clone());
    }
    if settings.allow_hash_redistribution {
        args.push("--allow-hash-redistribution".into());
    }
    if settings.validate_vk_hashes {
        args.push("--validate-vk-hashes".into());
    }

    args
}

fn read_token_for_core() -> Option<String> {
    let dir = crate::state::app_dir().ok()?;
    crate::vk::read_token(&dir)
}

pub async fn sleep_secs(secs: u64) {
    tokio::time::sleep(Duration::from_secs(secs)).await;
}
