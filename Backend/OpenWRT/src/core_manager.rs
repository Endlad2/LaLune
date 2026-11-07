// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Ядро CSQTT на OpenWRT.
//
// Fallback для dev-сборок без bundle: ~/.la-lune/csqtt-client-aarch64

use anyhow::{anyhow, Result};
use parking_lot::Mutex;
use regex::Regex;
use std::io;
use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};

use crate::core_logs::{CoreLogs, CORE_PREFIX, MAX_LINE_BYTES};
use crate::events::{Event, EventBus};

pub const LATEST_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST";
pub const CORE_URL_TEMPLATE: &str =
    "https://github.com/Endlad2/csqtt-core/releases/download/{VER}/{FILE}";
pub const PROXY_URL: &str = "http://31.77.148.203:8855/?url=";
pub const USER_AGENT_BROWSER: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
pub const USER_AGENT_CURL: &str = "curl/7.68.0";

/// Фиксированное имя ядра на OpenWRT.
pub fn core_filename() -> &'static str {
    "csqtt-client-aarch64"
}

/// Имя ассета в GitHub Releases.
pub fn core_asset_name() -> &'static str {
    "client-linux-arm64"
}

/// Release-сборки ARM64 и ramips содержат одинаковые три встроенных ядра.
pub fn supported_protocols() -> Vec<serde_json::Value> {
    use crate::bundled_cores::{available, Core};
    let bundled = available();
    Core::ALL.into_iter().filter(|core| bundled || *core == Core::Csqtt)
        .map(|core| serde_json::json!({
            "id": core.id(),
            "displayName": core.id(),
            "repo": if core == Core::Csqttr { "Endlad2/csqttr-core" } else { "Endlad2/csqtt-core" },
            "realtime": true,
            "description": "VK Calls, TURN и WRAP",
            "coreAsset": if bundled { core.filename() } else { core_asset_name() },
            "bundled": bundled,
        })).collect()
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

pub struct CoreProcess {
    pub child: Child,
    log_tasks: Vec<tokio::task::JoinHandle<()>>,
    readiness: Arc<Mutex<CoreReadiness>>,
    pub user: crate::linux_core::CoreUser,
}

#[derive(Default)]
pub struct CoreReadiness {
    params: Option<(String, String)>,
    active_ticks: u8,
}

impl CoreReadiness {
    fn observe(&mut self, line: &str) {
        if let Some(params) = crate::vpn::parse_tunconf(line) {
            self.params = Some(params);
        }
        if let Some((active, _)) = crate::vpn::parse_stats(line) {
            self.active_ticks = if active > 0 {
                self.active_ticks.saturating_add(1)
            } else {
                0
            };
        }
    }

    pub fn ready_params(&self) -> Option<(String, String)> {
        if self.active_ticks < 3 {
            return None;
        }
        Some(self.params.clone().unwrap_or_else(|| {
            (crate::vpn::DEFAULT_TUN_IP.into(), crate::vpn::DEFAULT_DNS.into())
        }))
    }
}

#[derive(Clone)]
struct CoreOutput {
    logs: Arc<Mutex<CoreLogs>>,
    events: EventBus,
    readiness: Arc<Mutex<CoreReadiness>>,
    secrets: Option<Regex>,
}

impl CoreOutput {
    async fn capture(self, pipe: impl AsyncRead + Unpin) {
        let mut reader = BufReader::new(pipe);
        let mut bytes = Vec::new();
        loop {
            let line = match read_core_line(&mut reader, &mut bytes).await {
                Ok(Some(false)) => String::from_utf8_lossy(&bytes),
                Ok(Some(true)) => "[oversized output omitted]".into(),
                Ok(None) => break,
                Err(err) => {
                    log::warn!("cannot read core output: {err}");
                    break;
                }
            };
            self.readiness.lock().observe(&line);
            let line = line.trim_end_matches('\r');
            let line = match &self.secrets {
                Some(secrets) => secrets.replace_all(line, "[redacted]"),
                None => line.into(),
            };
            let line = format!("{CORE_PREFIX}{}", hide_control_payloads(&line));
            self.logs.lock().record(line.clone());
            self.events.emit(Event::log(line));
        }
    }
}

fn hide_control_payloads(line: &str) -> &str {
    if line.contains("CAPTCHA_SOLVE|") {
        "[CAPTCHA] Ядро запросило решение капчи"
    } else if line.contains("Запрос (хеш:") {
        "[VK] Запрос по хешу звонка"
    } else {
        line
    }
}

fn core_secrets<'a>(args: &'a [String], extra: impl IntoIterator<Item = &'a str>) -> Result<Option<Regex>> {
    let mut secrets: Vec<_> = extra.into_iter().collect();
    for pair in args.windows(2) {
        match pair[0].as_str() {
            "--password" | "--token" => secrets.push(pair[1].as_str()),
            "--vk" => secrets.extend(pair[1].split(',')),
            _ => {}
        }
    }
    secrets.retain(|secret| !secret.is_empty() && secret.len() <= MAX_LINE_BYTES);
    if secrets.is_empty() {
        return Ok(None);
    }
    secrets.sort_unstable_by_key(|secret| std::cmp::Reverse(secret.len()));
    let pattern = secrets.into_iter().map(regex::escape).collect::<Vec<_>>().join("|");
    Regex::new(&pattern)
        .map(Some)
        .map_err(|_| anyhow!("cannot prepare core log redaction"))
}

async fn read_core_line(
    reader: &mut (impl tokio::io::AsyncBufRead + Unpin),
    output: &mut Vec<u8>,
) -> io::Result<Option<bool>> {
    output.clear();
    let mut oversized = false;
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return Ok((oversized || !output.is_empty()).then_some(oversized));
        }
        let newline = available.iter().position(|&b| b == b'\n');
        let end = newline.unwrap_or(available.len());
        oversized |= output.len() + end > MAX_LINE_BYTES - CORE_PREFIX.len();
        if !oversized {
            output.extend_from_slice(&available[..end]);
        }
        reader.consume(end + usize::from(newline.is_some()));
        if newline.is_some() {
            return Ok(Some(oversized));
        }
    }
}

impl CoreProcess {
    pub async fn spawn(
        core_path: &Path,
        args: &[String],
        logs: Arc<Mutex<CoreLogs>>,
        events: EventBus,
        password_env: Option<&str>,
        vk_token: Option<&str>,
    ) -> Result<Self> {
        let bootstrap = vk_token.map(vk_bootstrap);
        let secrets = core_secrets(args, password_env.into_iter().chain(vk_token)
            .chain(bootstrap.as_deref().map(str::trim_end)))?;
        let user = crate::linux_core::CoreUser::prepare(core_path)?;
        let mut cmd = Command::new(user.executable());
        user.configure(&mut cmd, args)?;
        if let Some(password) = password_env {
            cmd.env("CSQTT_PASSWORD", password);
        }
        cmd.stdin(if bootstrap.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let mut child = cmd.spawn()?;
        if let Some(line) = bootstrap {
            let stdin = child.stdin.as_mut().ok_or_else(|| anyhow!("Нет stdin ядра"))?;
            tokio::time::timeout(std::time::Duration::from_secs(5), stdin.write_all(line.as_bytes()))
                .await??;
            // Newer cores cancel AutoVK when the control pipe is closed.
        }
        let mut log_tasks = Vec::new();
        let readiness = Arc::new(Mutex::new(CoreReadiness::default()));
        let output = CoreOutput { logs, events, readiness: readiness.clone(), secrets };

        let line = format!("{CORE_PREFIX}spawned pid={:?}", child.id());
        output.logs.lock().record(line.clone());
        output.events.emit(Event::log(line));

        if let Some(stdout) = child.stdout.take() {
            log_tasks.push(tokio::spawn(output.clone().capture(stdout)));
        }

        if let Some(stderr) = child.stderr.take() {
            log_tasks.push(tokio::spawn(output.capture(stderr)));
        }

        Ok(Self { child, log_tasks, readiness, user })
    }

    pub fn readiness(&self) -> Arc<Mutex<CoreReadiness>> {
        self.readiness.clone()
    }

    pub async fn kill(&mut self) -> Result<()> {
        let result = self.child.kill().await;
        for task in self.log_tasks.drain(..) { task.abort(); let _ = task.await; }
        result?;
        Ok(())
    }
}

fn vk_bootstrap(token: &str) -> String {
    use base64::Engine;
    let json = serde_json::json!({"token": token});
    format!("VK_JS_BOOTSTRAP:{}\n", base64::engine::general_purpose::STANDARD.encode(json.to_string()))
}

/// Сборка аргументов ядра CSQTT для OpenWRT.
pub fn build_args(
    config: &crate::config::ConfigItem,
    settings: &crate::settings::Settings,
    listen_port: u16,
) -> Vec<String> {
    use crate::bundled_cores::{available, Core};
    let kind = Core::parse(&config.protocol).unwrap_or(Core::Csqtt);
    // Fallback: если в конфиге хешей нет — берём из settings.vk_hashes.
    let source_hashes = if config.hashes.trim().is_empty() {
        settings.vk_hashes.as_str()
    } else {
        config.hashes.as_str()
    };

    let normalized = source_hashes.replace([' ', '\t', '\n', '\r'], ",");
    let clean: Vec<String> = normalized
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .take(6)
        .collect();
    let hashes = if clean.is_empty() { String::new() } else { clean.join(",") };

    let auth_mode = if settings.auth_mode.is_empty() {
        "manual".to_string()
    } else {
        settings.auth_mode.clone()
    };
    let is_auto_vk = auth_mode == "autoVk";

    let hash_mode = if is_auto_vk { "auto_js" } else { "manual" };
    let vk_auth_mode = if is_auto_vk {
        "auto_js"
    } else if settings.vk_auth_mode.is_empty() {
        "vkcalls"
    } else {
        settings.vk_auth_mode.as_str()
    };

    let workers = settings.workers.clamp(
        crate::settings::MIN_WORKERS,
        crate::settings::MAX_WORKERS,
    );

    let mut args: Vec<String> = vec![
        "--peer".into(), config.peer.clone(),
        "--vk-hash-mode".into(), hash_mode.into(),
        "--vk-auth-mode".into(), vk_auth_mode.into(),
        "--listen".into(), format!("127.0.0.1:{}", listen_port),
        "-n".into(), workers.to_string(),
        "--obfs".into(), settings.obfs.clone(),
        "--fingerprint".into(), settings.fingerprint.clone(),
        "--client-ids".into(), settings.client_ids.clone(),
        "--captcha-mode".into(), settings.captcha_mode.clone(),
        "--turn-transport".into(), settings.turn_transport.clone(),
    ];

    if !kind.password_env() {
        args.push("--password".into());
        args.push(config.password.clone());
    }

    if !is_auto_vk {
        args.push("--vk".into());
        args.push(hashes);
    }

    if kind == Core::Legacy
        && !settings.device_id.trim().is_empty()
    {
        args.push("--device-id".into());
        args.push(settings.device_id.trim().into());
    }

    if !settings.turn_host.is_empty() {
        args.push("--turn".into());
        args.push(settings.turn_host.clone());
    }
    if !settings.turn_port.is_empty() {
        args.push("--port".into());
        args.push(settings.turn_port.clone());
    }
    if settings.allow_hash_redistribution && (kind == Core::Legacy || (!available() && kind == Core::Csqtt)) {
        args.push("--allow-hash-redistribution".into());
    }
    args
}

#[cfg(test)]
mod log_tests {
    use super::*;

    #[test]
    fn redacts_exact_core_secrets_in_one_pass() {
        let args = ["--password", "secret.key", "--vk", "r,another", "--token", "token-value"]
            .map(str::to_owned);
        let pattern = core_secrets(&args, []).unwrap().unwrap();
        assert_eq!(
            pattern.replace_all("secret.key token-value another", "[redacted]"),
            "[redacted] [redacted] [redacted]"
        );
    }

    #[test]
    fn readiness_uses_only_this_process_and_consecutive_ticks() {
        let mut previous = CoreReadiness::default();
        previous.observe("TUNCONF:10.1.0.2:1.1.1.1");
        for _ in 0..3 {
            previous.observe("Активных: 1");
        }
        assert_eq!(previous.ready_params(), Some(("10.1.0.2".into(), "1.1.1.1".into())));

        let mut current = CoreReadiness::default();
        assert!(current.ready_params().is_none());
        current.observe("Активных: 1");
        current.observe("Активных: 1");
        current.observe("Активных: 0");
        current.observe("Активных: 1");
        current.observe("Активных: 1");
        assert!(current.ready_params().is_none());
        current.observe("Активных: 1");
        assert_eq!(
            current.ready_params(),
            Some((crate::vpn::DEFAULT_TUN_IP.into(), crate::vpn::DEFAULT_DNS.into()))
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captcha_bootstrap_and_partial_hash_do_not_reach_history() {
        assert_eq!(hide_control_payloads("CAPTCHA_SOLVE|rjs|https://example.test|credential"),
            "[CAPTCHA] Ядро запросило решение капчи");
        assert_eq!(hide_control_payloads("[VK] Запрос (хеш: prefix123...)"),
            "[VK] Запрос по хешу звонка");
        assert_eq!(hide_control_payloads("regular core output"), "regular core output");
    }

    #[test]
    fn csqttr_uses_environment_password_and_only_supported_cli_flags() {
        let config = crate::config::ConfigItem {
            protocol: "CSQTTR".into(),
            password: "fixture-password".into(),
            ..Default::default()
        };
        let settings = crate::settings::Settings {
            auth_mode: "autoVk".into(),
            allow_hash_redistribution: true,
            validate_vk_hashes: true,
            ..Default::default()
        };
        let args = build_args(&config, &settings, 52230);
        for omitted in ["--password", "fixture-password", "--token", "--allow-hash-redistribution", "--validate-vk-hashes"] {
            assert!(!args.iter().any(|arg| arg == omitted));
        }
        assert!(args.windows(2).any(|pair| pair[0] == "--vk-hash-mode" && pair[1] == "auto_js"));
        assert!(crate::bundled_cores::Core::Csqttr.password_env());
    }

    #[test]
    fn auto_vk_bootstrap_is_one_json_record_on_stdin() {
        use base64::Engine;
        let line = vk_bootstrap("fixture-token");
        let payload = line.strip_prefix("VK_JS_BOOTSTRAP:").unwrap().strip_suffix('\n').unwrap();
        let bytes = base64::engine::general_purpose::STANDARD.decode(payload).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(json, serde_json::json!({"token":"fixture-token"}));
    }

    #[test]
    fn device_id_is_only_sent_to_legacy_core() {
        let settings = crate::settings::Settings {
            device_id: "fixture-device".into(),
            ..Default::default()
        };
        for protocol in ["CSQTT", "CSQTTR", "CSQTT 2.1.9"] {
            let config = crate::config::ConfigItem {
                protocol: protocol.into(),
                ..Default::default()
            };
            let args = build_args(&config, &settings, 52230);
            let device = args.windows(2).find(|pair| pair[0] == "--device-id");
            assert_eq!(device.map(|pair| pair[1].as_str()),
                (protocol == "CSQTT 2.1.9").then_some("fixture-device"));
        }
    }
}
