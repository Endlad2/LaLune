// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// VPN: TUN + UDP-мост. Копия Desktop/vpn.rs, но с адаптацией под OpenWRT:
//   * TUN-интерфейс: csqtt0
//   * Маршруты/DNS через `ip` и `/etc/resolv.conf`.
//   * Никаких bypass — как в Go-версии для Linux.

use anyhow::Result;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

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
    pub handle: Mutex<Option<crate::linux_tun::Session>>,
    pub core_uid: AtomicU32,
    pub operation: tokio::sync::Mutex<()>,
    pub watchdog: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl VpnRuntime {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            rx_bytes: Arc::new(AtomicU64::new(0)),
            tx_bytes: Arc::new(AtomicU64::new(0)),
            started_at: Arc::new(Mutex::new(None)),
            tun_conf: Arc::new(Mutex::new(None)),
            handle: Mutex::new(None),
            core_uid: AtomicU32::new(0),
            operation: tokio::sync::Mutex::new(()),
            watchdog: Mutex::new(None),
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

    pub async fn stop(&self) {
        let watchdog = { self.watchdog.lock().take() };
        if let Some(task) = watchdog { task.abort(); let _ = task.await; }
        self.stop_tun().await;
    }

    pub async fn stop_tun(&self) {
        self.running.store(false, Ordering::Release);
        let session = { self.handle.lock().take() };
        if let Some(session) = session { session.stop().await; }
        *self.started_at.lock() = None;
        *self.tun_conf.lock() = None;
    }
}

pub fn start_tun(runtime: Arc<VpnRuntime>, tun_ip: String, tun_dns: String, events: EventBus) -> Result<()> {
    let session = crate::linux_tun::Session::start(TUN_NAME, &tun_ip, &tun_dns, TUN_MTU,
        CORE_LISTEN_PORT, runtime.core_uid.load(Ordering::Acquire), runtime.running.clone(),
        runtime.rx_bytes.clone(), runtime.tx_bytes.clone(), events.clone())?;
    *runtime.handle.lock() = Some(session);
    *runtime.started_at.lock() = Some(Instant::now());
    *runtime.tun_conf.lock() = Some(TunConf { ip: tun_ip.clone(), dns: tun_dns.clone(), mtu: TUN_MTU });
    events.emit(Event::named("tun_ready", serde_json::json!({"ip":tun_ip,"dns":tun_dns,"mtu":TUN_MTU})));
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
