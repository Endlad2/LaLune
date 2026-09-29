//! Запуск ядра CSQTT + загрузка.
//!
//! На Windows ядро наследует админ-права родителя (Flutter .exe с манифестом
//! requireAdministrator). Явный UAC-запрос не нужен — Windows покажет его
//! один раз при старте самого приложения.
//!
//! stdout и stderr ядра пишутся в ~/.la-lune/core.log — иначе в GUI-сборке
//! они теряются (у окна нет консоли).

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use anyhow::{anyhow, Result};

use crate::state::Config;
use crate::settings::Settings;

pub const LATEST_URL: &str =
    "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST";
pub const CORE_URL_TEMPLATE: &str =
    "https://github.com/Endlad2/csqtt-core/releases/download/{ver}/{file}";

pub fn core_filename() -> &'static str {
    if cfg!(target_os = "windows") { "client-windows-x86_64.exe" }
    else if cfg!(target_os = "macos") { "client-macos-x86_64" }
    else { "client-linux-x86_64" }
}

pub fn core_log_path() -> PathBuf {
    crate::app_dir().join("core.log")
}

pub fn fetch_latest(logs: &mut VecDeque<String>) -> Option<String> {
    match crate::net::fetch_text(LATEST_URL) {
        Ok(v) => {
            logs.push_back(format!("[CORE] LATEST={v}"));
            Some(v)
        }
        Err(e) => {
            logs.push_back(format!("[CORE] ошибка LATEST: {e}"));
            None
        }
    }
}

pub fn download_core(logs: &mut VecDeque<String>) -> Result<()> {
    let version = fetch_latest(logs).ok_or_else(|| anyhow!("нет LATEST"))?;
    let file = core_filename();
    let url = CORE_URL_TEMPLATE
        .replace("{ver}", &version)
        .replace("{file}", file);
    logs.push_back(format!("[CORE] качаю {url}"));

    let dest = crate::core_path();
    crate::net::download_file(&url, &dest)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755));
    }
    let _ = std::fs::write(crate::latest_path(), version.clone());
    logs.push_back(format!("[CORE] сохранено {} ({})", dest.display(), version));
    Ok(())
}

pub fn spawn_core(
    cfg: &Config,
    s: &Settings,
    logs: &mut VecDeque<String>,
) -> Result<Child> {
    let core = crate::core_path();
    if !core.exists() {
        return Err(anyhow!("ядро не найдено: {}", core.display()));
    }

    // Чистим все хеши (могут приходить как `a,b` или `a+b`).
    let hashes_clean: Vec<String> = cfg
        .hashes
        .split(|c: char| c == ',' || c == '+' || c == ' ' || c == '\t' || c == '\n')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let hashes_joined = hashes_clean.join(",");

    // Собираем аргументы ядра (совпадает с Go-версией).
    let mut args: Vec<String> = vec![
        "-peer".into(),        cfg.peer.clone(),
        "-password".into(),    cfg.password.clone(),
        "-n".into(),           s.workers.to_string(),
        "-listen".into(),      "127.0.0.1:52230".into(),
        "-obfs".into(),        s.obfs.clone(),
        "-fingerprint".into(), s.fingerprint.clone(),
        "-client-ids".into(),  s.client_ids.clone(),
        "-vk-auth-mode".into(),s.vk_auth_mode.clone(),
        "-captcha-mode".into(),s.captcha_mode.clone(),
        "-device-id".into(),   s.device_id.clone(),
    ];
    if !hashes_joined.is_empty() {
        args.push("-vk".into());
        args.push(hashes_joined);
    }

    // Пишем лог отдельно: GUI-приложение не имеет консоли, поэтому
    // println!/eprintln! уходят в никуда.
    let log_path = core_log_path();
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&log_path)?;

    // Заголовок: полная командная строка — для отладки.
    {
        let mut f = log_file.try_clone()?;
        writeln!(f, "=== LaLune core ===")?;
        writeln!(f, "exe: {}", core.display())?;
        writeln!(f, "cwd: {}", crate::app_dir().display())?;
        writeln!(f, "args: {}", args.join(" "))?;
        writeln!(f, "===================")?;
    }

    let log_stderr = log_file.try_clone()?;

    let mut cmd = Command::new(&core);
    cmd.args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log_file))
        .stderr(Stdio::from(log_stderr))
        .current_dir(crate::app_dir());

    logs.push_back(format!(
        "[CORE] spawn: {} -peer {} -n {} (лог: {})",
        core.display(),
        cfg.peer,
        s.workers,
        log_path.display()
    ));

    let child = cmd.spawn().map_err(|e| anyhow!("spawn: {e}"))?;
    Ok(child)
}

/// Запускает фоновый поток, который читает core.log и пушит строки в state,
/// чтобы UI видел логи ядра в реальном времени через GetLogsJson.
pub fn tail_core_log_into(state: Arc<Mutex<crate::state::AppState>>) {
    std::thread::spawn(move || {
        let path = core_log_path();
        // Ждём появления файла до 10 секунд.
        for _ in 0..20 {
            if path.exists() { break; }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        if !path.exists() { return; }

        let file = match std::fs::File::open(&path) {
            Ok(f) => f,
            Err(_) => return,
        };
        let mut reader = BufReader::new(file);
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => {
                    // Достигли конца файла — ждём и пробуем снова.
                    std::thread::sleep(std::time::Duration::from_millis(500));
                }
                Ok(_) => {
                    let trimmed = line.trim_end_matches(['\r', '\n']).to_string();
                    if trimmed.is_empty() { continue; }
                    if let Ok(mut st) = state.lock() {
                        st.log(format!("[core] {trimmed}"));
                    }
                }
                Err(_) => break,
            }
        }
    });
}
