//! HTTP с фолбэком: прямой → прокси (браузерный UA) → прокси (curl UA).

use std::io::Read;
use std::time::Duration;
use anyhow::{anyhow, Result};

pub const PROXY_URL: &str = "http://31.77.148.203:8855/?url=";
pub const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) \
    AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

pub fn fetch_text(url: &str) -> Result<String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()?;

    let attempts = [
        (url.to_string(), USER_AGENT),
        (format!("{PROXY_URL}{}", urlencoding(url)), USER_AGENT),
        (format!("{PROXY_URL}{}", urlencoding(url)), "curl/7.68.0"),
    ];

    let mut last_err: Option<anyhow::Error> = None;
    for (u, ua) in attempts {
        match client.get(&u).header("User-Agent", ua).send() {
            Ok(resp) => {
                if resp.status().is_success() {
                    let mut s = String::new();
                    if resp.take(1 << 20).read_to_string(&mut s).is_ok() {
                        let trimmed = s.trim().to_string();
                        if !trimmed.is_empty()
                            && !trimmed.contains("Server error")
                            && !trimmed.contains("No connection adapters")
                        {
                            return Ok(trimmed);
                        }
                    }
                }
            }
            Err(e) => last_err = Some(e.into()),
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("не удалось загрузить {url}")))
}

pub fn download_file(url: &str, dest: &std::path::Path) -> Result<()> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()?;

    let attempts = [
        (url.to_string(), USER_AGENT),
        (format!("{PROXY_URL}{}", urlencoding(url)), USER_AGENT),
        (format!("{PROXY_URL}{}", urlencoding(url)), "curl/7.68.0"),
    ];

    for (u, ua) in attempts {
        if let Ok(resp) = client.get(&u).header("User-Agent", ua).send() {
            if resp.status().is_success() {
                let mut buf = Vec::new();
                if resp.take(64 << 20).read_to_end(&mut buf).is_ok() && buf.len() > 1024 {
                    if let Some(dir) = dest.parent() {
                        std::fs::create_dir_all(dir)?;
                    }
                    std::fs::write(dest, &buf)?;
                    return Ok(());
                }
            }
        }
    }
    Err(anyhow!("не удалось скачать {url}"))
}

pub fn urlencoding(s: &str) -> String {
    s.replace('%', "%25")
        .replace(':', "%3A")
        .replace('/', "%2F")
        .replace('?', "%3F")
        .replace('&', "%26")
        .replace('=', "%3D")
}
