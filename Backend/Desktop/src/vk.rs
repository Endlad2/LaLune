// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// VK: получение токена (через Token.ps1/Token.sh), валидация, auto-calls.

use anyhow::{anyhow, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

use crate::events::{Event, EventBus};

pub const VK_API_BASE: &str = "https://api.vk.ru/method/";
pub const VK_API_VERSION: &str = "5.199";

pub const VK_CLIENT_ID: &str = "7793118";
pub const VK_SCOPE: &str = "1073737727";
pub const VK_REDIRECT_URI: &str = "https://oauth.vk.ru/blank.html";

pub const TOKEN_PS1_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Token.ps1";
pub const TOKEN_SH_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Token.sh";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VkTokenState {
    pub has_token: bool,
    pub fetching: bool,
    pub progress: i32,
    pub message: String,
}

impl Default for VkTokenState {
    fn default() -> Self {
        Self {
            has_token: false,
            fetching: false,
            progress: 0,
            message: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VkLoginResponse {
    pub ok: bool,
    pub needs_ui: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub auth_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// Строит URL страницы авторизации VK (для мобильных платформ).
pub fn auth_url() -> String {
    format!(
        "https://oauth.vk.ru/authorize?client_id={}&scope={}&redirect_uri={}&display=page&response_type=token&revoke=1&v=5.199",
        VK_CLIENT_ID,
        VK_SCOPE,
        urlencode(VK_REDIRECT_URI)
    )
}

fn urlencode(s: &str) -> String {
    s.replace(':', "%3A").replace('/', "%2F")
}

/// Читает token.json из appDir. Поддерживает "Token" и "token".
pub fn read_token(app_dir: &PathBuf) -> Option<String> {
    let path = app_dir.join("token.json");
    let data = std::fs::read_to_string(&path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&data).ok()?;

    if let Some(t) = v.get("Token").and_then(|x| x.as_str()) {
        if !t.trim().is_empty() {
            return Some(t.trim().to_string());
        }
    }
    if let Some(t) = v.get("token").and_then(|x| x.as_str()) {
        if !t.trim().is_empty() {
            return Some(t.trim().to_string());
        }
    }
    None
}

/// Сохраняет токен в token.json.
pub fn save_token(app_dir: &PathBuf, token: &str) -> Result<()> {
    let path = app_dir.join("token.json");
    let payload = serde_json::json!({
        "Token": token,
        "SavedAt": chrono::Utc::now().to_rfc3339(),
    });
    std::fs::write(path, serde_json::to_string_pretty(&payload)?)?;
    Ok(())
}

pub fn delete_token(app_dir: &PathBuf) -> Result<()> {
    let path = app_dir.join("token.json");
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

pub fn token_state(app_dir: &PathBuf) -> VkTokenState {
    let has = read_token(app_dir).is_some();
    VkTokenState {
        has_token: has,
        fetching: false,
        progress: if has { 100 } else { 0 },
        message: if has {
            "VK token active".into()
        } else {
            String::new()
        },
    }
}

/// Запускает Token.ps1 (Windows) или Token.sh (Linux) в отдельном процессе.
pub async fn launch_token_fetcher(
    events: EventBus,
) -> Result<()> {
    #[cfg(target_os = "windows")]
    {
        let inner = format!(
            "$ErrorActionPreference='Continue'; \
             try {{ irm {} | iex }} \
             catch {{ Write-Host ('[Token.ps1] ' + $_.Exception.Message) -ForegroundColor Red; \
             Read-Host 'Press Enter to close' }}",
            TOKEN_PS1_URL
        );
        let status = Command::new("cmd")
            .args([
                "/c",
                "start",
                "",
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                &inner,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await?;

        if !status.success() {
            return Err(anyhow!("failed to start PowerShell (exit {:?})", status.code()));
        }
        events.emit(Event::log("[VK] Token.ps1 launched in a separate window"));
        Ok(())
    }

    #[cfg(target_os = "linux")]
    {
        let cmd_line = format!("curl -fsSL {} | bash", TOKEN_SH_URL);
        let status = Command::new("bash")
            .args(["-c", &cmd_line])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        events.emit(Event::log(format!(
            "[VK] Token.sh launched (pid {})",
            status.id().unwrap_or(0)
        )));
        Ok(())
    }

    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        let _ = events;
        Err(anyhow!("unsupported platform for token fetcher"))
    }
}

// ============================================================
//  VK API client (calls.start / calls.forceFinish)
// ============================================================

pub struct VkApiClient {
    http: Client,
    pub token: String,
}

#[derive(Debug, Default, Clone)]
pub struct VkCallStartResult {
    pub call_id: String,
    pub hash: String,
    pub error_code: i32,
    pub error_message: String,
    pub failed: bool,
}

impl VkCallStartResult {
    pub fn is_success(&self) -> bool {
        !self.call_id.is_empty() && !self.hash.is_empty()
    }
    pub fn token_invalid(&self) -> bool {
        matches!(self.error_code, 4 | 5 | 27 | 28)
    }
}

impl VkApiClient {
    pub fn new(token: String) -> Self {
        let http = Client::builder()
            .timeout(Duration::from_secs(8))
            .build()
            .expect("http client");
        Self { http, token }
    }

    async fn call(
        &self,
        method: &str,
        params: &[(&str, &str)],
    ) -> Result<serde_json::Value> {
        let url = format!("{}{}", VK_API_BASE, method);
        let mut form: Vec<(String, String)> = params
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        form.push(("v".to_string(), VK_API_VERSION.to_string()));

        let resp = self
            .http
            .post(&url)
            .bearer_auth(&self.token)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
            .header("Accept", "*/*")
            .header("Origin", "https://vk.com")
            .header("Referer", "https://vk.com/")
            .form(&form)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;
        Ok(resp)
    }

    pub async fn start_call(&self) -> VkCallStartResult {
        let j = match self.call("calls.start", &[]).await {
            Ok(v) => v,
            Err(e) => {
                return VkCallStartResult {
                    failed: true,
                    error_message: e.to_string(),
                    ..Default::default()
                }
            }
        };

        if let Some(err) = j.get("error") {
            return VkCallStartResult {
                error_code: err
                    .get("error_code")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0) as i32,
                error_message: err
                    .get("error_msg")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                failed: true,
                ..Default::default()
            };
        }

        let resp = match j.get("response") {
            Some(r) => r,
            None => {
                return VkCallStartResult {
                    failed: true,
                    error_message: "no response in calls.start".into(),
                    ..Default::default()
                }
            }
        };

        let call_id = resp
            .get("call_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let ok_join_link = resp
            .get("ok_join_link")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let join_link = resp
            .get("join_link")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        let mut hash = ok_join_link;
        if hash.is_empty() && !join_link.is_empty() {
            if let Some(seg) = join_link.rsplit('/').next() {
                hash = seg.to_string();
            }
        }

        if call_id.is_empty() || hash.is_empty() {
            return VkCallStartResult {
                failed: true,
                error_message: "empty call_id/hash".into(),
                ..Default::default()
            };
        }
        VkCallStartResult {
            call_id,
            hash,
            ..Default::default()
        }
    }

    pub async fn force_finish(&self, call_id: &str) -> bool {
        match self.call("calls.forceFinish", &[("call_id", call_id)]).await {
            Ok(j) => j.get("error").is_none(),
            Err(_) => false,
        }
    }
}

/// Как в Go-версии: ceil(workers / autoApiWorkers), ограничено 1..6.
pub fn call_count_for_workers(workers: i32, auto_api_workers: i32) -> i32 {
    let aw = if auto_api_workers <= 0 {
        crate::settings::DEFAULT_AUTO_API_WORKERS
    } else {
        auto_api_workers
    };
    let w = if workers <= 0 {
        crate::settings::DEFAULT_WORKERS
    } else {
        workers
    };
    let count = ((w as f64) / (aw as f64)).ceil() as i32;
    count.clamp(1, 6)
}

/// Проверяет токен через users.get — возвращает true, если токен валиден.
pub async fn validate_token(token: &str) -> Result<bool> {
    let client = VkApiClient::new(token.to_string());
    let j = client.call("users.get", &[]).await?;
    Ok(j.get("error").is_none())
}
