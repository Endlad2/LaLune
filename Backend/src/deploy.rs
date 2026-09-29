//! Запуск deploy-manager (Rust-бинарь).

use std::collections::VecDeque;
use std::process::Command;
use anyhow::{anyhow, Result};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct DeployRequest {
    #[serde(default)] pub protocol: String,
    #[serde(default)] pub host: String,
    #[serde(default, rename = "sshPort")] pub ssh_port: i64,
    #[serde(default)] pub user: String,
    #[serde(default, rename = "usePassword")] pub use_password: bool,
    #[serde(default)] pub password: String,
    #[serde(default, rename = "keyPath")] pub key_path: String,
    #[serde(default, rename = "manualPorts")] pub manual_ports: bool,
    #[serde(default, rename = "corePort")] pub core_port: i64,
    #[serde(default, rename = "warpPort")] pub warp_port: i64,
    #[serde(default, rename = "listenPort")] pub listen_port: i64,
}

fn deploy_bin() -> &'static str {
    if cfg!(target_os = "windows") { "deploy-manager.exe" } else { "deploy-manager" }
}

pub fn run_deploy(req_json: &str, logs: &mut VecDeque<String>) -> Result<String> {
    let req: DeployRequest = serde_json::from_str(req_json)?;

    let exe = std::env::current_exe()?;
    let dir = exe.parent().unwrap_or(std::path::Path::new("."));
    let bin = dir.join(deploy_bin());
    if !bin.exists() {
        return Err(anyhow!("deploy-manager не найден: {}", bin.display()));
    }

    let mut args: Vec<String> = vec![
        "deploy".into(),
        "--protocol".into(), req.protocol.to_lowercase(),
        "--host".into(), req.host.clone(),
        "--user".into(), if req.user.is_empty() { "root".into() } else { req.user.clone() },
    ];
    if req.ssh_port > 0 {
        args.push("--port".into());
        args.push(req.ssh_port.to_string());
    }
    if req.use_password {
        if !req.password.is_empty() {
            args.push("--password".into());
            args.push(req.password.clone());
        }
    } else if !req.key_path.is_empty() {
        args.push("--key".into());
        args.push(req.key_path.clone());
    }
    if req.manual_ports {
        args.push("--manual-ports".into());
        if req.core_port > 0 { args.push("--core-port".into()); args.push(req.core_port.to_string()); }
        if req.warp_port > 0 { args.push("--warp-port".into()); args.push(req.warp_port.to_string()); }
        if req.listen_port > 0 { args.push("--listen-port".into()); args.push(req.listen_port.to_string()); }
    }

    logs.push_back(format!("[DEPLOY] {} {}", bin.display(), args.join(" ")));

    let out = Command::new(&bin).args(&args).output()?;
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    Ok(format!("{stdout}{stderr}"))
}
