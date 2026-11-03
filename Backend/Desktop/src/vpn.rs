// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// VPN: TUN-интерфейс, UDP-мост к ядру, маршруты, DNS, bypass.
// Для PaperFlux в режиме proxy TUN оборачивает SOCKS5: маршруты
// отправляют трафик на локальный SOCKS-прокси через tun2socks-подобный мост.
// Здесь упрощённый вариант — используется тот же UDP-мост, что и для CSQTT
// (ядро PaperFlux в режиме raw умеет работать напрямую с пакетами).
//
// ВАЖНО: для PaperFlux --mode proxy мы подсовываем ОС маршруты через TUN,
// а TUN-мост сам подключается к SOCKS5 127.0.0.1:{CORE_LISTEN_PORT}.

use anyhow::Result;
#[cfg(target_os = "windows")]
use anyhow::anyhow;
use parking_lot::{Mutex, RwLock};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
#[cfg(target_os = "linux")]
use std::sync::atomic::AtomicU32;
use std::sync::Arc;
use std::time::Instant;
#[cfg(target_os = "windows")]
use std::time::Duration;

use crate::events::{Event, EventBus};

pub const CORE_LISTEN_PORT: u16 = 1080;
pub const TUN_MTU: u16 = 1400;
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
    pub bypass_routes: Arc<Mutex<Vec<String>>>,
    pub proxy_routes: Arc<Mutex<Vec<String>>>,
    pub physical_gateway: Arc<Mutex<String>>,
    pub phase: Arc<RwLock<String>>,
    pub phase_message: Arc<RwLock<String>>,

    #[cfg(target_os = "windows")]
    pub wintun: crate::wintun::SharedWintunSession,

    #[cfg(target_os = "linux")]
    pub handle: Mutex<Option<crate::linux_tun::Session>>,
    #[cfg(target_os = "linux")]
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
            bypass_routes: Arc::new(Mutex::new(Vec::new())),
            proxy_routes: Arc::new(Mutex::new(Vec::new())),
            physical_gateway: Arc::new(Mutex::new(String::new())),
            phase: Arc::new(RwLock::new("disconnected".into())),
            phase_message: Arc::new(RwLock::new(String::new())),

            #[cfg(target_os = "windows")]
            wintun: crate::wintun::new_shared_session(),

            #[cfg(target_os = "linux")]
            handle: Mutex::new(None),
            #[cfg(target_os = "linux")]
            core_uid: AtomicU32::new(0),
            operation: tokio::sync::Mutex::new(()),
            watchdog: Mutex::new(None),
        }
    }

    pub fn status(&self, config_id: i64) -> VpnStatus {
        let running = self.running.load(Ordering::Relaxed);
        let started_at = *self.started_at.lock();
        let uptime = started_at.map(|t| t.elapsed().as_secs()).unwrap_or(0);
        let since = started_at
            .map(|_| chrono::Utc::now().to_rfc3339())
            .unwrap_or_default();

        let phase = self.phase.read().clone();
        let message = self.phase_message.read().clone();
        VpnStatus {
            state: if running && phase == "disconnected" { "connected".into() } else { phase },
            connected: running,
            uptime_sec: uptime,
            config_id,
            message,
            since,
        }
    }

    pub fn set_phase(&self, state: &str, message: &str) {
        *self.phase.write() = state.to_string();
        *self.phase_message.write() = message.to_string();
    }

    pub fn stats(&self) -> VpnStats {
        VpnStats {
            rx_bytes: self.rx_bytes.load(Ordering::Relaxed),
            tx_bytes: self.tx_bytes.load(Ordering::Relaxed),
            rx_rate: 0,
            tx_rate: 0,
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
        #[cfg(target_os = "windows")]
        { *self.wintun.lock() = None; }
        #[cfg(target_os = "linux")]
        {
            let session = { self.handle.lock().take() };
            if let Some(session) = session { session.stop().await; }
        }
        *self.started_at.lock() = None;
        *self.tun_conf.lock() = None;
        self.set_phase("disconnected", "");
    }
}

// ============================================================
//  Desktop routing helpers
// ============================================================

fn parse_ipv4_prefix(input: &str) -> Option<(Ipv4Addr, u8, Ipv4Addr)> {
    let trimmed = input.trim();
    if trimmed.is_empty() { return None; }
    let (ip_text, prefix) = match trimmed.split_once('/') {
        Some((ip, prefix)) => (ip, prefix.parse::<u8>().ok()?),
        None => (trimmed, 32),
    };
    if prefix > 32 { return None; }
    let ip = ip_text.parse::<Ipv4Addr>().ok()?;
    let mask_u32 = if prefix == 0 { 0 } else { u32::MAX << (32 - prefix) };
    let network = Ipv4Addr::from(u32::from(ip) & mask_u32);
    let mask = Ipv4Addr::from(mask_u32);
    Some((network, prefix, mask))
}

pub fn configure_bypass_routes(
    runtime: &VpnRuntime,
    mode: &str,
    raw: &str,
    events: &EventBus,
) {
    runtime.bypass_routes.lock().clear();
    if mode == "whitelist" {
        events.emit(Event::log(
            "[ROUTE] desktop whitelist mode is not applied yet; use blacklist for direct-IP exclusions",
        ));
        return;
    }

    let mut routes = runtime.bypass_routes.lock();
    for value in raw.lines().flat_map(|line| line.split(',')) {
        let value = value.trim();
        if value.is_empty() { continue; }
        if let Some((network, prefix, _)) = parse_ipv4_prefix(value) {
            let normalized = format!("{}/{}", network, prefix);
            if !routes.iter().any(|existing| existing == &normalized) {
                routes.push(normalized);
            }
        } else if value.parse::<std::net::Ipv6Addr>().is_ok() || value.contains(':') {
            // Current desktop tunnel is IPv4-only, therefore IPv6 traffic already
            // stays on the physical network and does not need a bypass route.
            events.emit(Event::log(format!(
                "[ROUTE] IPv6 exclusion {} is already direct (desktop tunnel is IPv4-only)",
                value
            )));
        } else {
            events.emit(Event::log(format!("[ROUTE] ignored invalid IP/CIDR: {}", value)));
        }
    }
}

#[cfg(target_os = "windows")]
fn get_physical_gateway() -> String {
    use std::process::Command;
    let out = match Command::new("cmd").args(["/c", "route", "print", "0.0.0.0"]).output() {
        Ok(o) => o,
        Err(_) => return String::new(),
    };
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        if !line.contains("0.0.0.0") { continue; }
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() >= 3 && fields[0] == "0.0.0.0" {
            return fields[2].to_string();
        }
    }
    String::new()
}

#[cfg(target_os = "windows")]
fn add_windows_bypass(prefix: &str, gateway: &str) {
    use std::process::Command;
    let Some((network, _plen, mask)) = parse_ipv4_prefix(prefix) else { return; };
    if gateway.is_empty() { return; }
    let destination = network.to_string();
    let _ = Command::new("route")
        .args([
            "ADD",
            &destination,
            "MASK",
            &mask.to_string(),
            gateway,
            "METRIC",
            "1",
        ])
        .output();
}

#[cfg(target_os = "windows")]
fn remove_windows_bypass(prefix: &str) {
    use std::process::Command;
    let Some((network, _plen, mask)) = parse_ipv4_prefix(prefix) else { return; };
    let _ = Command::new("route")
        .args(["DELETE", &network.to_string(), "MASK", &mask.to_string()])
        .output();
}

pub fn tunnel_ipv4(runtime: &VpnRuntime) -> Result<Ipv4Addr> {
    let conf = runtime.tun_conf.lock().clone()
        .ok_or_else(|| anyhow::anyhow!("tunnel parameters are not ready"))?;
    conf.ip.parse::<Ipv4Addr>()
        .map_err(|e| anyhow::anyhow!("invalid tunnel IPv4 {}: {}", conf.ip, e))
}

pub fn tunnel_dns_ipv4(runtime: &VpnRuntime) -> Option<Ipv4Addr> {
    runtime.tun_conf.lock().as_ref().and_then(|conf| {
        conf.dns.split(',').map(str::trim).find_map(|v| v.parse::<Ipv4Addr>().ok())
    })
}

pub fn ensure_proxy_route(runtime: &VpnRuntime, target: IpAddr, events: &EventBus) -> Result<()> {
    let IpAddr::V4(ip) = target else {
        anyhow::bail!("desktop SOCKS5 tunnel currently supports IPv4 destinations only");
    };
    let prefix = format!("{}/32", ip);
    {
        let routes = runtime.proxy_routes.lock();
        if routes.iter().any(|existing| existing == &prefix) {
            return Ok(());
        }
    }

    #[cfg(target_os = "windows")]
    {
        use std::process::Command;
        let output = Command::new("netsh")
            .args([
                "interface", "ipv4", "add", "route",
                &format!("prefix={}", prefix),
                "interface=\"CSQTT\"",
                "nexthop=0.0.0.0",
                "metric=1",
                "store=active",
            ])
            .output()
            .map_err(|e| anyhow::anyhow!("netsh route {}: {}", prefix, e))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            anyhow::bail!("netsh route {} failed: {}{}", prefix, stdout.trim(), stderr.trim());
        }
    }

    #[cfg(target_os = "linux")]
    {
        use std::process::Command;
        let source = tunnel_ipv4(runtime)?;
        let output = Command::new("ip")
            .args([
                "-4", "route", "replace", &prefix,
                "dev", "csqtt0",
                "src", &source.to_string(),
            ])
            .output()
            .map_err(|e| anyhow::anyhow!("ip route {}: {}", prefix, e))?;
        if !output.status.success() {
            anyhow::bail!(
                "ip route {} failed: {}",
                prefix,
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
    }

    runtime.proxy_routes.lock().push(prefix.clone());
    events.emit(Event::log(format!("[PROXY] tunnel route ready: {}", prefix)));
    Ok(())
}

// ============================================================
//  Маршруты и DNS
// ============================================================

#[cfg(target_os = "windows")]
pub fn setup_routes(runtime: &VpnRuntime, tun_ip: &str, tun_dns: &str, events: &EventBus) {
    #[cfg(target_os = "windows")]
    setup_routes_windows(runtime, tun_ip, tun_dns, events);
}

#[cfg(target_os = "windows")]
pub fn cleanup_routes(runtime: &VpnRuntime, events: &EventBus) {
    #[cfg(target_os = "windows")]
    cleanup_routes_windows(runtime, events);
}

#[cfg(target_os = "windows")]
fn setup_routes_windows(runtime: &VpnRuntime, tun_ip: &str, tun_dns: &str, events: &EventBus) {
    use std::process::Command;

    let gateway = get_physical_gateway();
    if !gateway.is_empty() {
        events.emit(Event::log(format!("[TUN] physical gateway: {}", gateway)));
    }
    *runtime.physical_gateway.lock() = gateway.clone();

    let bypass_list = runtime.bypass_routes.lock().clone();
    for prefix in &bypass_list {
        add_windows_bypass(prefix, &gateway);
    }

    let _ = Command::new("netsh")
        .args(["interface", "ipv4", "set", "address",
               "name=\"CSQTT\"", "source=static",
               &format!("address={}", tun_ip), "mask=255.255.255.255"])
        .output();

    let _ = Command::new("netsh")
        .args(["interface", "ipv4", "set", "subinterface",
               "\"CSQTT\"", &format!("mtu={}", TUN_MTU), "store=active"])
        .output();

    let mut dns_index = 1;
    for dns in tun_dns.split(',') {
        let dns = dns.trim();
        if dns.is_empty() || dns_index > 2 { continue; }
        let _ = Command::new("netsh")
            .args(["interface", "ipv4", "add", "dnsservers",
                   "name=\"CSQTT\"",
                   &format!("address={}", dns),
                   &format!("index={}", dns_index),
                   "validate=no"])
            .output();
        dns_index += 1;
    }

    let _ = Command::new("netsh")
        .args(["interface", "ipv4", "add", "route",
               "prefix=0.0.0.0/0", "interface=\"CSQTT\"",
               "nexthop=0.0.0.0", "metric=5", "store=active"])
        .output();

    events.emit(Event::log("[TUN] Windows routes + DNS configured"));
}

#[cfg(target_os = "windows")]
fn cleanup_routes_windows(runtime: &VpnRuntime, events: &EventBus) {
    use std::process::Command;

    let _ = Command::new("netsh")
        .args(["interface", "ipv4", "delete", "route",
               "prefix=0.0.0.0/0", "interface=\"CSQTT\"", "store=active"])
        .output();

    let bypass_list = runtime.bypass_routes.lock().clone();
    for prefix in &bypass_list {
        remove_windows_bypass(prefix);
    }
    runtime.bypass_routes.lock().clear();

    let proxy_routes = runtime.proxy_routes.lock().clone();
    for prefix in &proxy_routes {
        let _ = Command::new("netsh")
            .args([
                "interface", "ipv4", "delete", "route",
                &format!("prefix={}", prefix),
                "interface=\"CSQTT\"",
                "store=active",
            ])
            .output();
    }
    runtime.proxy_routes.lock().clear();
    *runtime.physical_gateway.lock() = String::new();

    events.emit(Event::log("[TUN] Windows routes cleaned"));
}

// ============================================================
//  Windows: Wintun + UDP-мост
// ============================================================

#[cfg(target_os = "windows")]
pub fn start_tun(
    runtime: Arc<VpnRuntime>,
    tun_ip: String,
    tun_dns: String,
    events: EventBus,
) -> Result<()> {
    start_tun_windows(runtime, tun_ip, tun_dns, events, true)
}

#[cfg(target_os = "windows")]
pub fn start_proxy_tun(
    runtime: Arc<VpnRuntime>,
    tun_ip: String,
    tun_dns: String,
    events: EventBus,
) -> Result<()> {
    start_tun_windows(runtime, tun_ip, tun_dns, events, false)
}

#[cfg(target_os = "windows")]
fn configure_proxy_adapter_windows(tun_ip: &str, events: &EventBus) {
    use std::process::Command;

    let _ = Command::new("netsh")
        .args([
            "interface", "ipv4", "set", "address",
            "name=\"CSQTT\"", "source=static",
            &format!("address={}", tun_ip), "mask=255.255.255.255",
        ])
        .output();

    let _ = Command::new("netsh")
        .args([
            "interface", "ipv4", "set", "subinterface",
            "\"CSQTT\"", &format!("mtu={}", TUN_MTU), "store=active",
        ])
        .output();

    // Proxy mode deliberately has no default route and does not replace system DNS.
    let _ = Command::new("netsh")
        .args([
            "interface", "ipv4", "delete", "route",
            "prefix=0.0.0.0/0", "interface=\"CSQTT\"", "store=active",
        ])
        .output();

    events.emit(Event::log("[TUN] Windows proxy adapter configured without default route"));
}

#[cfg(target_os = "windows")]
fn start_tun_windows(
    runtime: Arc<VpnRuntime>,
    tun_ip: String,
    tun_dns: String,
    events: EventBus,
    full_tunnel: bool,
) -> Result<()> {
    use std::net::UdpSocket;
    use std::path::PathBuf;

    let app_dir = crate::state::app_dir()?;
    let dll_path: PathBuf = app_dir.join("wintun.dll");
    events.emit(Event::log(format!("[WINTUN] загружаю DLL: {}", dll_path.display())));

    let session = crate::wintun::WintunSession::open_or_create(&dll_path)?;
    events.emit(Event::log(format!(
        "[WINTUN] адаптер {} готов, ring={} bytes",
        session.adapter_name(),
        crate::wintun::WINTUN_RING_CAPACITY
    )));

    let sock = UdpSocket::bind("127.0.0.1:0")?;
    sock.connect(format!("127.0.0.1:{}", CORE_LISTEN_PORT))?;

    use std::os::windows::io::AsRawSocket;
    const SOL_SOCKET: i32 = 0xFFFF;
    const SO_RCVBUF: i32 = 0x1002;
    const SO_SNDBUF: i32 = 0x1001;
    const BUFSIZE: i32 = 8 * 1024 * 1024;

    extern "system" {
        fn setsockopt(s: usize, level: i32, optname: i32, optval: *const i8, optlen: i32) -> i32;
    }

    let raw = sock.as_raw_socket();
    unsafe {
        let v = BUFSIZE;
        setsockopt(raw as usize, SOL_SOCKET, SO_RCVBUF, &v as *const i32 as *const i8, std::mem::size_of::<i32>() as i32);
        setsockopt(raw as usize, SOL_SOCKET, SO_SNDBUF, &v as *const i32 as *const i8, std::mem::size_of::<i32>() as i32);
    }

    let sock = Arc::new(sock);

    *runtime.tun_conf.lock() = Some(TunConf {
        ip: tun_ip.clone(),
        dns: tun_dns.clone(),
        mtu: TUN_MTU,
    });

    {
        let mut guard = runtime.wintun.lock();
        *guard = Some(session);
    }

    runtime.rx_bytes.store(0, Ordering::Relaxed);
    runtime.tx_bytes.store(0, Ordering::Relaxed);
    runtime.running.store(true, Ordering::Release);
    *runtime.started_at.lock() = Some(Instant::now());

    if full_tunnel {
        setup_routes(&runtime, &tun_ip, &tun_dns, &events);
    } else {
        configure_proxy_adapter_windows(&tun_ip, &events);
    }

    let running_a = runtime.running.clone();
    let tx_bytes = runtime.tx_bytes.clone();
    let events_a = events.clone();
    let wintun_a = runtime.wintun.clone();
    let sock_a = sock.clone();

    let wintun_b = runtime.wintun.clone();
    let sock_b = sock.clone();
    let running_b = runtime.running.clone();
    let rx_bytes = runtime.rx_bytes.clone();

    std::thread::Builder::new()
        .name("wintun->udp".into())
        .spawn(move || {
            let mut buf = vec![0u8; 65535];
            while running_a.load(Ordering::Relaxed) {
                let n = {
                    let guard = wintun_a.lock();
                    match guard.as_ref() {
                        Some(sess) => sess.recv_into(&mut buf),
                        None => 0,
                    }
                };
                if n == 0 {
                    std::thread::sleep(Duration::from_micros(200));
                    continue;
                }
                match sock_a.send(&buf[..n]) {
                    Ok(sent) => { tx_bytes.fetch_add(sent as u64, Ordering::Relaxed); }
                    Err(e) => { events_a.emit(Event::log(format!("[TUN] udp send: {}", e))); }
                }
            }
            log::info!("[TUN] wintun->udp stop");
        })
        .map_err(|e| anyhow!("spawn wintun->udp: {}", e))?;

    std::thread::Builder::new()
        .name("udp->wintun".into())
        .spawn(move || {
            let mut buf = vec![0u8; 65535];
            while running_b.load(Ordering::Relaxed) {
                let n = match sock_b.recv(&mut buf) {
                    Ok(n) if n > 0 => n,
                    Ok(_) => continue,
                    Err(_) => break,
                };
                let guard = wintun_b.lock();
                if let Some(sess) = guard.as_ref() {
                    if let Err(_e) = sess.send_packet(&buf[..n]) {
                        std::thread::sleep(Duration::from_micros(200));
                    } else {
                        rx_bytes.fetch_add(n as u64, Ordering::Relaxed);
                    }
                }
            }
            log::info!("[TUN] udp->wintun stop");
        })
        .map_err(|e| anyhow!("spawn udp->wintun: {}", e))?;

    events.emit(Event::log(if full_tunnel {
        "[TUN] Wintun bridge started (full tunnel)"
    } else {
        "[TUN] Wintun bridge started (SOCKS5 proxy mode)"
    }));
    Ok(())
}

// ============================================================
//  Linux: TUN через крейт tun
// ============================================================

#[cfg(target_os = "linux")]
pub fn start_tun(
    runtime: Arc<VpnRuntime>,
    tun_ip: String,
    tun_dns: String,
    events: EventBus,
) -> Result<()> {
    start_tun_linux(runtime, tun_ip, tun_dns, events, true)
}

#[cfg(target_os = "linux")]
pub fn start_proxy_tun(
    runtime: Arc<VpnRuntime>,
    tun_ip: String,
    tun_dns: String,
    events: EventBus,
) -> Result<()> {
    start_tun_linux(runtime, tun_ip, tun_dns, events, false)
}

#[cfg(target_os = "linux")]
fn start_tun_linux(
    runtime: Arc<VpnRuntime>,
    tun_ip: String,
    tun_dns: String,
    events: EventBus,
    full_tunnel: bool,
) -> Result<()> {
    let bypass = runtime.bypass_routes.lock().clone();
    let session = crate::linux_tun::Session::start(
        "csqtt0",
        &tun_ip,
        &tun_dns,
        TUN_MTU,
        CORE_LISTEN_PORT,
        runtime.core_uid.load(Ordering::Acquire),
        runtime.running.clone(),
        runtime.rx_bytes.clone(),
        runtime.tx_bytes.clone(),
        events.clone(),
        full_tunnel,
        bypass,
    )?;
    *runtime.handle.lock() = Some(session);
    *runtime.started_at.lock() = Some(Instant::now());
    *runtime.tun_conf.lock() = Some(TunConf { ip: tun_ip, dns: tun_dns, mtu: TUN_MTU });
    events.emit(Event::log(if full_tunnel {
        "[TUN] bridge started (Linux full tunnel)"
    } else {
        "[TUN] bridge started (Linux SOCKS5 proxy mode)"
    }));
    Ok(())
}

// ============================================================
//  Парсинг логов ядра
// ============================================================

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
    if !line.contains("Активных:") {
        return None;
    }
    let idx = line.find("Активных:")?;
    let after = &line[idx + "Активных:".len()..];
    let trimmed = after.trim_start();

    let end = trimmed
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(trimmed.len());
    if end == 0 {
        return None;
    }
    let active: i32 = trimmed[..end].parse().ok()?;

    let traffic = line
        .find("Трафик:")
        .and_then(|i| {
            let after = &line[i + "Трафик:".len()..];
            let t = after.trim_start();
            let end = t
                .find(|c: char| !c.is_ascii_digit() && c != '.')
                .unwrap_or(t.len());
            t[..end].parse::<f64>().ok()
        })
        .unwrap_or(0.0);

    Some((active, traffic))
}

pub fn extract_ipv4_addrs(line: &str) -> Vec<String> {
    use std::net::Ipv4Addr;
    let mut result = Vec::new();
    let bytes = line.as_bytes();
    let mut i = 0;

    while i < bytes.len() {
        if !bytes[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        let start = i;
        let mut dots = 0;
        let mut last_was_digit = false;

        while i < bytes.len() {
            let c = bytes[i];
            if c.is_ascii_digit() {
                last_was_digit = true;
                i += 1;
            } else if c == b'.' && last_was_digit && dots < 3 {
                dots += 1;
                last_was_digit = false;
                i += 1;
            } else {
                break;
            }
        }

        if dots == 3 && last_was_digit {
            if let Ok(candidate) = std::str::from_utf8(&bytes[start..i]) {
                if candidate.parse::<Ipv4Addr>().is_ok() {
                    result.push(candidate.to_string());
                }
            }
        } else {
            i = start + 1;
        }
    }

    result
}

#[cfg(all(test, target_os = "windows"))]
mod windows_lifecycle_tests {
    use super::*;

    #[tokio::test]
    async fn stop_cancels_watchdog_and_clears_runtime_without_tun() {
        struct OnDrop(Arc<AtomicBool>);
        impl Drop for OnDrop {
            fn drop(&mut self) { self.0.store(true, Ordering::Release); }
        }

        let runtime = VpnRuntime::new();
        let started = Arc::new(tokio::sync::Notify::new());
        let cancelled = Arc::new(AtomicBool::new(false));
        let started_task = started.clone();
        let cancelled_task = cancelled.clone();
        *runtime.watchdog.lock() = Some(tokio::spawn(async move {
            let _on_drop = OnDrop(cancelled_task);
            started_task.notify_one();
            std::future::pending::<()>().await;
        }));
        started.notified().await;
        runtime.running.store(true, Ordering::Release);
        *runtime.started_at.lock() = Some(Instant::now());
        *runtime.tun_conf.lock() = Some(TunConf {
            ip: "192.0.2.1".into(), dns: "192.0.2.53".into(), mtu: TUN_MTU,
        });

        tokio::time::timeout(Duration::from_secs(2), runtime.stop()).await.unwrap();
        assert!(cancelled.load(Ordering::Acquire));
        assert!(!runtime.running.load(Ordering::Acquire));
        assert!(runtime.watchdog.lock().is_none());
        assert!(runtime.wintun.lock().is_none());
        assert!(runtime.started_at.lock().is_none());
        assert!(runtime.tun_conf.lock().is_none());
        runtime.stop().await;
    }
}
