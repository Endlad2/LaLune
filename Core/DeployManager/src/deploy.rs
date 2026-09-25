// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SSH execution layer. We deliberately shell out to the OS `ssh` client
// instead of linking a native SSH library, so this binary builds on every
// target (Windows, Linux, macOS, Android) without a C toolchain.
//
// Password auth (portable, no native deps):
//   1. If `sshpass` is installed -> `sshpass -e` with SSHPASS env.
//   2. Otherwise -> generate a temporary SSH_ASKPASS helper (a .cmd on
//      Windows, a chmod +x sh script elsewhere) that prints the password
//      from the SSHPASS env var, and run ssh with SSH_ASKPASS /
//      SSH_ASKPASS_REQUIRE=force. This works on Windows OpenSSH >= 8.4,
//      Linux and macOS.
// Key auth uses `ssh -i <key>`. No auth falls back to the SSH agent.

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

/// Build a temporary SSH_ASKPASS helper that emits $SSHPASS. Returns its path.
/// On Windows we create a .cmd; elsewhere a chmod +x /bin/sh script.
fn write_askpass_helper() -> Result<std::path::PathBuf> {
    let dir = std::env::temp_dir();
    let pid = std::process::id();
    #[cfg(windows)]
    {
        let path = dir.join(format!("lalune_askpass_{pid}.cmd"));
        // %SSHPASS% is expanded by cmd at runtime; ssh reads this on stdout.
        let body = "@echo off\r\necho %SSHPASS%\r\n";
        std::fs::write(&path, body).context("write askpass helper (.cmd)")?;
        Ok(path)
    }
    #[cfg(not(windows))]
    {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(format!("lalune_askpass_{pid}.sh"));
        let body = "#!/bin/sh\nprintf '%s\\n' \"$SSHPASS\"\n";
        std::fs::write(&path, body).context("write askpass helper (.sh)")?;
        let mut perms = std::fs::metadata(&path)?.permissions();
        perms.set_mode(0o700);
        std::fs::set_permissions(&path, perms).context("chmod askpass helper")?;
        Ok(path)
    }
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

    // Askpass env (only used when we must supply the password via helper).
    let mut askpass_env: Option<(std::path::PathBuf, String)> = None;

    let (program, mut cmd_args) = if let Some(pw) = &args.password {
        if have_sshpass() {
            let mut a = vec!["-e".to_string()];
            a.extend(ssh_args.clone());
            ("sshpass".to_string(), a)
        } else {
            // Portable fallback: SSH_ASKPASS helper.
            let helper = write_askpass_helper()?;
            askpass_env = Some((helper.clone(), pw.clone()));
            ssh_args.push("-o".into());
            ssh_args.push("PreferredAuthentications=password,keyboard-interactive".into());
            ssh_args.push("-o".into());
            ssh_args.push("PubkeyAuthentication=no".into());
            ("ssh".to_string(), ssh_args.clone())
        }
    } else {
        ("ssh".to_string(), ssh_args.clone())
    };

    // Final argv tail: remote + "bash -s".
    cmd_args.push(remote.to_string());
    cmd_args.push("bash -s".to_string());

    // If sshpass is the program, the real binary name must come first.
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

    // Wire the askpass helper into the environment when we made one.
    if let Some((helper, pw)) = &askpass_env {
        cmd.env("SSHPASS", pw);
        cmd.env("SSH_ASKPASS", helper);
        cmd.env("SSH_ASKPASS_REQUIRE", "force");
        // Some builds only consult askpass when DISPLAY is set.
        if std::env::var_os("DISPLAY").is_none() {
            cmd.env("DISPLAY", ":0");
        }
        // Make sure ssh is not in batch mode (batch disables askpass).
        cmd.env("GIT_SSH_COMMAND", "");
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

    // Best-effort cleanup of the askpass helper.
    if let Some((helper, _)) = askpass_env {
        let _ = std::fs::remove_file(helper);
    }
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
/// Any missing asset / failed download aborts with a clear, non-zero exit.
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
  armv7l) ASSET_ARCH="arm" ;;
  *) ASSET_ARCH="$ARCH" ;;
esac
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ASSET="{bin}-${{OS}}-${{ASSET_ARCH}}"
URL="https://github.com/{repo}/releases/latest/download/${{ASSET}}"
DEST="/usr/local/bin/{bin}"
echo "[install] downloading $URL"
rm -f "$DEST"
if command -v curl >/dev/null 2>&1; then
  curl -fSL --retry 3 "$URL" -o "$DEST"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$DEST" "$URL"
else
  echo "[install] error: neither curl nor wget available" >&2
  exit 1
fi
if [ ! -s "$DEST" ]; then
  echo "[install] error: downloaded file is empty ($URL)" >&2
  exit 1
fi
chmod +x "$DEST"
echo "[install] installed $DEST ($(stat -c %s "$DEST" 2>/dev/null || echo '?') bytes)"

if command -v systemctl >/dev/null 2>&1; then
  cat >/etc/systemd/system/{bin}.service <<UNIT
[Unit]
Description=LaLune {proto} core
After=network-online.target
[Service]
ExecStart=/usr/local/bin/{bin}{flags}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable {bin}.service
  systemctl restart {bin}.service
  if ! systemctl is-active --quiet {bin}.service; then
    echo "[install] error: {bin}.service failed to start" >&2
    systemctl --no-pager -l status {bin}.service >&2 || true
    journalctl -u {bin}.service -n 40 --no-pager >&2 || true
    exit 1
  fi
  echo "[install] systemd service {bin}.service started"
else
  pkill -f "{bin}" >/dev/null 2>&1 || true
  nohup /usr/local/bin/{bin}{flags} >/var/log/{bin}.log 2>&1 &
  sleep 1
  if ! pgrep -f "{bin}" >/dev/null 2>&1; then
    echo "[install] error: {bin} failed to start (see /var/log/{bin}.log)" >&2
    tail -n 40 /var/log/{bin}.log >&2 || true
    exit 1
  fi
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