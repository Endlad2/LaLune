//! Запуск ядра CSQTT + загрузка.

use std::collections::VecDeque;
use std::process::{Child, Command, Stdio};
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

    let hashes_clean: Vec<String> = cfg
        .hashes
        .split(|c| c == ',' || c == '+' || c == ' ' || c == '\t' || c == '\n')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let hashes_joined = hashes_clean.join(",");

    let mut cmd = Command::new(&core);
    cmd.arg("-peer").arg(&cfg.peer)
        .arg("-password").arg(&cfg.password)
        .arg("-n").arg(s.workers.to_string())
        .arg("-listen").arg("127.0.0.1:52230")
        .arg("-obfs").arg(&s.obfs)
        .arg("-fingerprint").arg(&s.fingerprint)
        .arg("-client-ids").arg(&s.client_ids)
        .arg("-vk-auth-mode").arg(&s.vk_auth_mode)
        .arg("-captcha-mode").arg(&s.captcha_mode)
        .arg("-device-id").arg(&s.device_id);

    if !hashes_joined.is_empty() {
        cmd.arg("-vk").arg(&hashes_joined);
    }

    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    logs.push_back(format!(
        "[CORE] spawn: {} -peer {} -n {}",
        core.display(),
        cfg.peer,
        s.workers
    ));

    let mut child = cmd.spawn().map_err(|e| anyhow!("spawn: {e}"))?;

    if let Some(out) = child.stdout.take() {
        std::thread::spawn(move || {
            use std::io::BufRead;
            let r = std::io::BufReader::new(out);
            for line in r.lines().map_while(|x| x.ok()) {
                println!("[core] {line}");
            }
        });
    }
    if let Some(err) = child.stderr.take() {
        std::thread::spawn(move || {
            use std::io::BufRead;
            let r = std::io::BufReader::new(err);
            for line in r.lines().map_while(|x| x.ok()) {
                eprintln!("[core:err] {line}");
            }
        });
    }

    Ok(child)
}
