// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// VPN: TUN + UDP-мост. Копия Desktop/vpn.rs, но с адаптацией под OpenWRT:
//   * TUN-интерфейс: csqtt0
//   * Маршруты/DNS через `ip` и `/etc/resolv.conf`.
//   * Никаких bypass — как в Go-версии для Linux.

use anyhow::{anyhow, Result};
use parking_lot::Mutex;
use std::io::{Read, Write};
use std::net::UdpSocket;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use tun::Configuration;

use crate::events::{Event, EventBus};

pub const CORE_LISTEN_PORT: u16 = 52230;
pub const TUN_NAME: &str = "csqtt0";
pub const TUN_MTU: u16 = 1300;
pub const DEFAULT_TUN_IP: &str = "10.66.67.12";
pub const DEFAULT_DNS: &str = "8.8.8.8,8.8.4.4";

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VpnStatus {
    pub state: String,
    pub connected: bool,
    pub uptime_sec: u64,
    pub config_id: i64,
    pub message: String,
    pub since: String,
}

impl Default for VpnStatus {
    fn default() -> Self {
        Self {
            state: "disconnected".into(),
            connected: false,
            uptime_sec: 0,
            config_id: 0,
            message: String::new(),
            since: String::new(),
        }
    }
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VpnStats {
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rx_rate: u64,
    pub tx_rate: u64,
    pub active_sessions: i32,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TunConf {
    pub ip: String,
    pub dns: String,
    pub mtu: u16,
}

pub struct VpnRuntime {
    pub running: Arc<AtomicBool>,
    pub rx_bytes: Arc<AtomicU64>,
    pub tx_bytes: Arc<AtomicU64>,
    pub started_at: Arc<Mutex<Option<Instant>>>,
    pub tun_conf: Arc<Mutex<Option<TunConf>>>,
    pub handle: Arc<Mutex<Option<thread::JoinHandle<()>>>>,
}

impl VpnRuntime {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            rx_bytes: Arc::new(AtomicU64::new(0)),
            tx_bytes: Arc::new(AtomicU64::new(0)),
            started_at: Arc::new(Mutex::new(None)),
            tun_conf: Arc::new(Mutex::new(None)),
            handle: Arc::new(Mutex::new(None)),
        }
    }

    pub fn status(&self, config_id: i64) -> VpnStatus {
        let running = self.running.load(Ordering::Relaxed);
        let started_at = *self.started_at.lock();
        let uptime = started_at.map(|t| t.elapsed().as_secs()).unwrap_or(0);
        let since = started_at.map(|_| chrono::Utc::now().to_rfc3339()).unwrap_or_default();

        VpnStatus {
            state: if running { "connected".into() } else { "disconnected".into() },
            connected: running,
            uptime_sec: uptime,
            config_id,
            message: String::new(),
            since,
        }
    }

    pub fn stats(&self) -> VpnStats {
        VpnStats {
            rx_bytes: self.rx_bytes.load(Ordering::Relaxed),
            tx_bytes: self.tx_bytes.load(Ordering::Relaxed),
            rx_rate: 0, tx_rate: 0,
            active_sessions: if self.running.load(Ordering::Relaxed) { 1 } else { 0 },
        }
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::Relaxed);
        if let Some(h) = self.handle.lock().take() { let _ = h.join(); }
        *self.started_at.lock() = None;
        *self.tun_conf.lock() = None;
    }
}

pub fn setup_routes(tun_ip: &str, tun_dns: &str, events: &EventBus) {
    for dns in tun_dns.split(',') {
        let dns = dns.trim();
        if dns.is_empty() { continue; }
        run_sudo(&format!("echo 'nameserver {}' >> /etc/resolv.conf", dns), events);
    }
    run_sudo(&format!("ip route add default dev {}", TUN_NAME), events);
    let _ = tun_ip;
}

pub fn cleanup_routes(events: &EventBus) {
    run_sudo(&format!("ip route del default dev {} 2>/dev/null || true", TUN_NAME), events);
}

fn run_sudo(command: &str, events: &EventBus) {
    let result = Command::new("sh").args(["-c", &format!("sudo {}", command)]).output();
    match result {
        Ok(out) if out.status.success() => {
            events.emit(Event::log(format!("[TUN][sudo] OK: {}", command)));
        }
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr);
            events.emit(Event::log(format!("[TUN][sudo] failed: {} — {}", command, err.trim())));
        }
        Err(e) => {
            events.emit(Event::log(format!("[TUN][sudo] spawn error: {} — {}", command, e)));
        }
    }
}

pub fn start_tun(
    runtime: Arc<VpnRuntime>,
    tun_ip: String,
    tun_dns: String,
    events: EventBus,
) -> Result<()> {
    let mut config = Configuration::default();
    config
        .name(TUN_NAME)
        .address(&tun_ip)
        .netmask("255.255.255.255")
        .mtu(TUN_MTU as i32)
        .up();

    let dev = tun::create(&config).map_err(|e| anyhow!("tun create failed: {}", e))?;
    let dev = Arc::new(Mutex::new(dev));

    events.emit(Event::named(
        "tun_ready",
        serde_json::json!({ "ip": tun_ip, "dns": tun_dns, "mtu": TUN_MTU }),
    ));

    *runtime.tun_conf.lock() = Some(TunConf { ip: tun_ip.clone(), dns: tun_dns.clone(), mtu: TUN_MTU });

    let sock = UdpSocket::bind("127.0.0.1:0")?;
    sock.connect(format!("127.0.0.1:{}", CORE_LISTEN_PORT))?;
    let sock = Arc::new(sock);

    runtime.running.store(true, Ordering::Relaxed);
    *runtime.started_at.lock() = Some(Instant::now());

    setup_routes(&tun_ip, &tun_dns, &events);

    let running = runtime.running.clone();
    let rx = runtime.rx_bytes.clone();
    let tx = runtime.tx_bytes.clone();

    let dev_w = dev.clone();
    let sock_w = sock.clone();
    let running_w = running.clone();
    let rx_w = rx.clone();
    let tx_w = tx.clone();

    let handle = thread::spawn(move || {
        let dev_r = dev_w.clone();
        let sock_r = sock_w.clone();
        let running_r = running_w.clone();
        let tx_r = tx_w.clone();
        let h1 = thread::spawn(move || {
            let mut buf = vec![0u8; 65535];
            while running_r.load(Ordering::Relaxed) {
                let n = { let mut guard = dev_r.lock(); guard.read(&mut buf).unwrap_or(0) };
                if n > 0 {
                    if sock_r.send(&buf[..n]).is_ok() { tx_r.fetch_add(n as u64, Ordering::Relaxed); }
                } else {
                    thread::sleep(Duration::from_millis(2));
                }
            }
        });

        let dev_w2 = dev_w.clone();
        let sock_w2 = sock_w.clone();
        let running_w2 = running_w.clone();
        let rx_w2 = rx_w.clone();
        let h2 = thread::spawn(move || {
            let mut buf = vec![0u8; 65535];
            while running_w2.load(Ordering::Relaxed) {
                match sock_w2.recv(&mut buf) {
                    Ok(n) if n > 0 => {
                        let mut guard = dev_w2.lock();
                        if guard.write(&buf[..n]).is_ok() { rx_w2.fetch_add(n as u64, Ordering::Relaxed); }
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
        });

        let _ = h1.join();
        let _ = h2.join();
    });

    *runtime.handle.lock() = Some(handle);
    events.emit(Event::log("[TUN] bridge started"));
    Ok(())
}

pub fn parse_tunconf(line: &str) -> Option<(String, String)> {
    if let Some(rest) = line.strip_prefix("TUNCONF:") {
        let parts: Vec<&str> = rest.splitn(2, ':').collect();
        if parts.len() == 2 {
            return Some((parts[0].trim().to_string(), parts[1].trim().to_string()));
        }
    }
    if line.contains("Tunnel IP:") && line.contains("DNS:") {
        let ip_idx = line.find("Tunnel IP:")?;
        let dns_idx = line.find("DNS:")?;
        if dns_idx > ip_idx {
            let ip_part = line[ip_idx + 10..dns_idx].trim().trim_end_matches('|').trim();
            let ip_clean = ip_part.split('/').next()?.trim().to_string();
            let dns_part = line[dns_idx + 4..].split('|').next()?.trim().to_string();
            if !ip_clean.is_empty() && !dns_part.is_empty() {
                return Some((ip_clean, dns_part));
            }
        }
    }
    None
}

pub fn parse_stats(line: &str) -> Option<(i32, f64)> {
    if !line.contains("Активных:") { return None; }
    let idx = line.find("Активных:")?;
    let after = &line[idx + "Активных:".len()..];
    let trimmed = after.trim_start();
    let end = trimmed.find(|c: char| !c.is_ascii_digit()).unwrap_or(trimmed.len());
    if end == 0 { return None; }
    let active: i32 = trimmed[..end].parse().ok()?;
    let traffic = line.find("Трафик:").and_then(|i| {
        let after = &line[i + "Трафик:".len()..];
        let t = after.trim_start();
        let end = t.find(|c: char| !c.is_ascii_digit() && c != '.').unwrap_or(t.len());
        t[..end].parse::<f64>().ok()
    }).unwrap_or(0.0);
    Some((active, traffic))
}

pub fn extract_ipv4_addrs(line: &str) -> Vec<String> {
    let mut result = Vec::new();
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if !bytes[i].is_ascii_digit() { i += 1; continue; }
        let start = i;
        let mut dots = 0;
        let mut last_was_digit = false;
        while i < bytes.len() {
            let c = bytes[i];
            if c.is_ascii_digit() { last_was_digit = true; i += 1; }
            else if c == b'.' && last_was_digit && dots < 3 { dots += 1; last_was_digit = false; i += 1; }
            else { break; }
        }
        if dots == 3 && last_was_digit {
            if let Ok(candidate) = std::str::from_utf8(&bytes[start..i]) {
                if candidate.parse::<std::net::Ipv4Addr>().is_ok() {
                    result.push(candidate.to_string());
                }
            }
        } else { i = start + 1; }
    }
    result
}
