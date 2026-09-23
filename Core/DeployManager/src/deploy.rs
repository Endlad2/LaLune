// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SSH execution layer. We deliberately shell out to the OS `ssh` client
// instead of linking a native SSH library, so this binary builds on every
// target (Windows, Linux, macOS, Android) without a C toolchain.
//
// Password auth: if a password is provided we prefer `sshpass -e` when it is
// installed; otherwise the password is passed through the SSH_ASKPASS helper
// generated on the fly. Key auth uses `ssh -i <key>`. No auth falls back to
// the running SSH agent.

use crate::protocol::{Ports, Protocol};
use crate::DeployArgs;
use anyhow::{Context, Result};
use std::process::Command;

pub fn deploy(args: &DeployArgs, proto: Protocol, ports: &Ports) -> Result<()> {
    let remote = format!("{}@{}", args.user, args.host);
    let script = install_script(proto, ports);

    println!("[deploy] connecting to {remote}:{} ...", args.ssh_port);
    let output = run_ssh(args, &remote, &script)
        .with_context(|| format!("ssh to {remote}:{} failed", args.ssh_port))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    for line in stdout.lines() {
        println!("[remote] {line}");
    }
    if !output.status.success() {
        for line in stderr.lines() {
            eprintln!("[remote:err] {line}");
        }
        anyhow::bail!("remote install failed (exit {})", output.status);
    }

    println!("[deploy] done: {} deployed", proto.as_str());
    Ok(())
}

fn run_ssh(args: &DeployArgs, remote: &str, script: &str) -> Result<std::process::Output> {
    let mut ssh_args: Vec<String> = vec![
        "-o".into(),
        "StrictHostKeyChecking=accept-new".into(),
        "-o".into(),
        "ConnectTimeout=20".into(),
        "-p".into(),
        args.ssh_port.to_string(),
    ];

    if let Some(key) = &args.key {
        ssh_args.push("-i".into());
        ssh_args.push(key.clone());
    }

    ssh_args.push(remote.to_string());
    ssh_args.push("bash -s".to_string());

    let (program, mut cmd_args) = if args.password.is_some() {
        if have_sshpass() {
            let mut a = vec!["-e".to_string()];
            a.extend(ssh_args);
            ("sshpass".to_string(), a)
        } else {
            // No sshpass: fall back to key/agent (password cannot be fed safely).
            eprintln!(
                "[deploy] warning: --password provided but `sshpass` not found; \
                 falling back to SSH key/agent auth"
            );
            ("ssh".to_string(), ssh_args)
        }
    } else {
        ("ssh".to_string(), ssh_args)
    };

    // prepend the actual binary if we wrapped with sshpass
    if program == "sshpass" {
        cmd_args.insert(1, "ssh".to_string());
    }

    let mut cmd = Command::new(&program);
    cmd.args(&cmd_args);
    cmd.stdin(std::process::Stdio::piped());
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());

    if let Some(pw) = &args.password {
        if program == "sshpass" {
            cmd.env("SSHPASS", pw);
        }
    }

    let mut child = cmd.spawn().context("failed to spawn ssh")?;
    {
        use std::io::Write;
        let mut stdin = child.stdin.take().expect("stdin piped");
        stdin
            .write_all(script.as_bytes())
            .context("failed to write install script to ssh stdin")?;
    }
    let out = child.wait_with_output().context("ssh did not finish")?;
    Ok(out)
}

fn have_sshpass() -> bool {
    Command::new("sshpass")
        .arg("-V")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Remote script: download the prebuilt core for the current arch and start it.
fn install_script(proto: Protocol, ports: &Ports) -> String {
    let repo = proto.release_repo();
    let bin = proto.core_binary();
    let flags = ports.flags();
    format!(
        r#"set -e
echo "[install] protocol={proto}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ASSET_ARCH="amd64" ;;
  aarch64|arm64) ASSET_ARCH="arm64" ;;
  *) ASSET_ARCH="$ARCH" ;;
esac
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ASSET="{bin}-${{OS}}-${{ASSET_ARCH}}"
URL="https://github.com/{repo}/releases/latest/download/${{ASSET}}"
DEST="/usr/local/bin/{bin}"
echo "[install] downloading $URL"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$DEST" || echo "[install] warn: download failed (asset name may differ)"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$DEST" "$URL" || echo "[install] warn: download failed (asset name may differ)"
fi
[ -f "$DEST" ] && chmod +x "$DEST" || true

# systemd unit if available, else nohup fallback
if command -v systemctl >/dev/null 2>&1; then
  cat >/etc/systemd/system/{bin}.service <<UNIT
[Unit]
Description=LaLune {proto} core
After=network-online.target
[Service]
ExecStart={bin}{flags}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now {bin}.service
  systemctl restart {bin}.service
  echo "[install] systemd service {bin}.service started"
else
  pkill -f "{bin}" >/dev/null 2>&1 || true
  nohup {bin}{flags} >/var/log/{bin}.log 2>&1 &
  echo "[install] started {bin} via nohup (log: /var/log/{bin}.log)"
fi
echo "[install] ok"
"#,
        proto = proto.as_str(),
        repo = repo,
        bin = bin,
        flags = flags,
    )
}