//! Кнопка «Войти»: запуск LaLuneTokenFetcher или PowerShell-скрипта.
//!
//! Windows:
//!   1. Проверяем, что в <app_dir>/vk-token-fetcher/browsers есть chromium-XXXX.
//!      Если нет — возвращаем ошибку, НИЧЕГО не запуская.
//!   2. Запускаем видимое окно PowerShell через `cmd /c start "" powershell ...`
//!      с one-command Token.ps1:
//!
//!        powershell -NoProfile -ExecutionPolicy Bypass -Command
//!          "$Env:PLAYWRIGHT_BROWSERS_PATH='<...>'; irm <URL> | iex"
//!
//! Linux:
//!   Ищем LaLuneTokenFetcher рядом с exe (или в <app_dir>/vk-token-fetcher/)
//!   и запускаем с PLAYWRIGHT_BROWSERS_PATH=<app_dir>/vk-token-fetcher/browsers.
//!   Если бинарь отсутствует — пробуем скачать его из LaLune releases.
//!
//! macOS: пока не поддерживаем (тот же Linux-путь, но с .app bundle).
//!
//! После запуска fetcher пишет токен в ~/.la-lune/token.json — UI поллит
//! GetVKTokenState и видит его там.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{anyhow, Result};

use crate::{app_dir, net, token_path};

/// One-command скрипт с GitHub, который скачивает ZIP, распаковывает его,
/// выставляет PLAYWRIGHT_BROWSERS_PATH и запускает LaLuneTokenFetcher.exe
/// в видимом окне.
pub const TOKEN_PS_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Token.ps1";

pub fn vk_fetcher_dir() -> PathBuf {
    app_dir().join("vk-token-fetcher")
}

pub fn playwright_browsers_dir() -> PathBuf {
    vk_fetcher_dir().join("browsers")
}

/// Проверяем, что в `<vk-token-fetcher>/browsers` есть хотя бы одна папка
/// `chromium-XXXX`.
pub fn has_chromium_installed() -> bool {
    let dir = playwright_browsers_dir();
    let read = match std::fs::read_dir(&dir) {
        Ok(r) => r,
        Err(_) => return false,
    };
    for entry in read.flatten() {
        if let Ok(ft) = entry.file_type() {
            if ft.is_dir() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with("chromium") {
                    return true;
                }
            }
        }
    }
    false
}

fn launcher_exe_name() -> &'static str {
    if cfg!(target_os = "windows") { "LaLuneTokenFetcher.exe" } else { "LaLuneTokenFetcher" }
}

/// Возможные пути к локальному LaLuneTokenFetcher:
///   1. рядом с текущим exe
///   2. <app_dir>/vk-token-fetcher/
///   3. <app_dir>/
pub fn find_local_fetcher() -> Option<PathBuf> {
    let name = launcher_exe_name();
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join(name));
            candidates.push(dir.join("vk-token-fetcher").join(name));
        }
    }
    candidates.push(vk_fetcher_dir().join(name));
    candidates.push(app_dir().join(name));
    for c in candidates {
        if c.exists() { return Some(c); }
    }
    None
}

/// Установка Chromium (Linux-фолбэк): если локальный fetcher есть, а Chromium
/// нет — вызываем `playwright install chromium` из директории fetcher'а.
fn install_chromium(logs: &mut VecDeque<String>) -> Result<()> {
    let fetcher = find_local_fetcher()
        .ok_or_else(|| anyhow!("LaLuneTokenFetcher не найден"))?;
    let dir = fetcher.parent().unwrap_or_else(|| Path::new("."));

    let browsers = playwright_browsers_dir();
    std::fs::create_dir_all(&browsers)?;

    // Ищем playwright.ps1 / playwright / playwright.cmd рядом с бинарём.
    let candidates = ["playwright.ps1", "playwright.cmd", "playwright.exe", "playwright"];
    for name in candidates {
        let path = dir.join(name);
        if !path.exists() { continue; }
        let argv: Vec<String> = if name.ends_with(".ps1") {
            vec!["pwsh".into(), "-NoProfile".into(), "-ExecutionPolicy".into(),
                 "Bypass".into(), "-File".into(), path.to_string_lossy().into(),
                 "install".into(), "chromium".into()]
        } else {
            vec![path.to_string_lossy().into(), "install".into(), "chromium".into()]
        };
        logs.push_back(format!("[VK] install chromium через {}", path.display()));
        let mut cmd = Command::new(&argv[0]);
        cmd.args(&argv[1..])
            .current_dir(dir)
            .env("PLAYWRIGHT_BROWSERS_PATH", &browsers)
            .env("PLAYWRIGHT_SKIP_BROWSER_GC", "1");
        match cmd.status() {
            Ok(s) if s.success() => {
                logs.push_back("[VK] chromium установлен".into());
                return Ok(());
            }
            Ok(s) => logs.push_back(format!("[VK] install chromium exit={s}")),
            Err(e) => logs.push_back(format!("[VK] install chromium error: {e}")),
        }
    }
    Err(anyhow!("не удалось установить chromium — playwright не найден"))
}

/// Запуск видимого окна PowerShell с Token.ps1 (только Windows).
///
/// `cmd /c start "" powershell -NoProfile -ExecutionPolicy Bypass -Command "..."`
/// — гарантирует новое консольное окно, независимо от того, есть ли у
/// родительского процесса своя консоль.
fn start_fetcher_via_token_ps(logs: &mut VecDeque<String>) -> Result<()> {
    if !has_chromium_installed() {
        return Err(anyhow!(
            "Chromium не установлен в {} — установите Chromium кнопкой или переустановите LaLuneTokenFetcher",
            playwright_browsers_dir().display()
        ));
    }

    let browsers = playwright_browsers_dir();
    let browsers_str = browsers.to_string_lossy().replace('\'', "''");

    let inner = format!(
        "$ErrorActionPreference='Continue'; \
         $Env:PLAYWRIGHT_BROWSERS_PATH='{browsers}'; \
         try {{ irm {url} | iex }} catch {{ \
            Write-Host ('[Token.ps1] Ошибка: ' + $_.Exception.Message) -ForegroundColor Red; \
            Read-Host 'Нажмите Enter, чтобы закрыть окно' }}",
        browsers = browsers_str,
        url = TOKEN_PS_URL,
    );

    logs.push_back(format!("[VK] PLAYWRIGHT_BROWSERS_PATH={}", browsers.display()));
    logs.push_back("[VK] запускаю Token.ps1 в отдельном окне PowerShell".into());

    let mut cmd = Command::new("cmd");
    cmd.args(["/c", "start", "", "powershell",
              "-NoProfile", "-ExecutionPolicy", "Bypass",
              "-Command", &inner]);
    cmd.current_dir(vk_fetcher_dir());
    cmd.env("PLAYWRIGHT_BROWSERS_PATH", browsers.to_string_lossy().to_string());
    cmd.env("PLAYWRIGHT_SKIP_BROWSER_GC", "1");

    cmd.spawn().map_err(|e| anyhow!("не удалось запустить PowerShell: {e}"))?;
    Ok(())
}

/// Запуск локального fetcher'а напрямую (Linux/macOS).
fn start_fetcher_captured(logs: &mut VecDeque<String>) -> Result<()> {
    let fetcher = find_local_fetcher().ok_or_else(|| {
        anyhow!(
            "LaLuneTokenFetcher не найден. Скачайте его из LaLune releases \
             или установите через однокоммандник"
        )
    })?;

    let browsers = playwright_browsers_dir();
    std::fs::create_dir_all(&browsers)?;

    logs.push_back(format!("[VK] fetcher: {}", fetcher.display()));
    logs.push_back(format!("[VK] PLAYWRIGHT_BROWSERS_PATH={}", browsers.display()));

    let mut cmd = Command::new(&fetcher);
    if let Some(dir) = fetcher.parent() { cmd.current_dir(dir); }
    cmd.env("PLAYWRIGHT_BROWSERS_PATH", browsers.to_string_lossy().to_string());
    cmd.env("PLAYWRIGHT_SKIP_BROWSER_GC", "1");
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::null());
    cmd.stderr(std::process::Stdio::null());

    cmd.spawn().map_err(|e| anyhow!("не удалось запустить fetcher: {e}"))?;
    Ok(())
}

/// Единая точка входа, вызывается из `AppState::vk_login`.
pub fn start_fetcher(logs: &mut VecDeque<String>) -> Result<()> {
    // Если на Linux Chromium нет — установим (Playwright install chromium).
    if cfg!(target_os = "linux") && !has_chromium_installed() {
        logs.push_back("[VK] Chromium не найден, устанавливаю...".into());
        if let Err(e) = install_chromium(logs) {
            logs.push_back(format!("[VK] install chromium: {e}"));
            return Err(e);
        }
    }

    if cfg!(target_os = "windows") {
        start_fetcher_via_token_ps(logs)
    } else {
        start_fetcher_captured(logs)
    }
}
