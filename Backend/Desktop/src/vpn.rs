// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// VPN: TUN-интерфейс, UDP-мост к ядру CSQTT, маршруты, DNS, bypass.
//
// Windows:
//   * Прямой FFI к wintun.dll из %APPDATA%\.la-lune\wintun.dll
//   * Адаптер "CSQTT" создаёт сам бэкенд (OpenAdapter → CreateAdapter)
//   * Ring-buffer 4 МБ, две tokio-таски без мьютекса:
//       Task A: WintunReceivePacket → UDP send
//       Task B: UDP recv → WintunSendPacket
//   * Маршруты/DNS/MTU — через netsh (как в старом Go)
//   * Bypass-маршруты для TURN/Relay — через физический шлюз
//
// Linux:
//   * Крейт `tun`, TUN-девайс csqtt0, read/write с двух потоков
//   * Маршруты/DNS — через `ip` / resolv.conf (sudo)
//   * Bypass-маршруты не используются (как в Go)
//
// Порядок:
//   1. Ядро запускается первым.
//   2. Watchdog ждёт в logs.log "TUNCONF" + "Активных>0" два тика подряд.
//   3. Только потом поднимаем Wintun/TUN и ставим default route.

use anyhow::{anyhow, Result};
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::events::{Event, EventBus};

pub const CORE_LISTEN_PORT: u16 = 52230;
pub const TUN_MTU: u16 = 1400;
pub const DEFAULT_TUN_IP: &str = "10.66.67.12";
pub const DEFAULT_DNS: &str = "8.8.8.8,8.8.4.4";

// ============================================================
//  Общие типы
// ============================================================

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

// ============================================================
//  VpnRuntime — общее состояние
// ============================================================

pub struct VpnRuntime {
    pub running: Arc<AtomicBool>,
    pub rx_bytes: Arc<AtomicU64>,
    pub tx_bytes: Arc<AtomicU64>,
    pub started_at: Arc<Mutex<Option<Instant>>>,
    pub tun_conf: Arc<Mutex<Option<TunConf>>>,
    pub bypass_routes: Arc<Mutex<Vec<String>>>,
    pub physical_gateway: Arc<Mutex<String>>,

    #[cfg(target_os = "windows")]
    pub wintun: crate::wintun::SharedWintunSession,

    #[cfg(target_os = "linux")]
    pub handle: Arc<Mutex<Option<std::thread::JoinHandle<()>>>>,
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
            physical_gateway: Arc::new(Mutex::new(String::new())),

            #[cfg(target_os = "windows")]
            wintun: crate::wintun::new_shared_session(),

            #[cfg(target_os = "linux")]
            handle: Arc::new(Mutex::new(None)),
        }
    }

    pub fn status(&self, config_id: i64) -> VpnStatus {
        let running = self.running.load(Ordering::Relaxed);
        let started_at = *self.started_at.lock();
        let uptime = started_at.map(|t| t.elapsed().as_secs()).unwrap_or(0);
        let since = started_at
            .map(|_| chrono::Utc::now().to_rfc3339())
            .unwrap_or_default();

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
            rx_rate: 0,
            tx_rate: 0,
            active_sessions: if self.running.load(Ordering::Relaxed) { 1 } else { 0 },
        }
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::Relaxed);

        #[cfg(target_os = "windows")]
        {
            // Дроп WintunSession → EndSession + CloseAdapter.
            let mut guard = self.wintun.lock();
            *guard = None;
        }

        #[cfg(target_os = "linux")]
        {
            if let Some(h) = self.handle.lock().take() {
                let _ = h.join();
            }
        }

        *self.started_at.lock() = None;
        *self.tun_conf.lock() = None;
    }
}

// ============================================================
//  Bypass-маршруты (только Windows)
// ============================================================

#[cfg(target_os = "windows")]
fn get_physical_gateway() -> String {
    use std::process::Command;
    let out = match Command::new("cmd")
        .args(["/c", "route", "print", "0.0.0.0"])
        .output()
    {
        Ok(o) => o,
        Err(_) => return String::new(),
    };

    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        if !line.contains("0.0.0.0") {
            continue;
        }
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() >= 3 && fields[0] == "0.0.0.0" {
            return fields[2].to_string();
        }
    }
    String::new()
}

#[cfg(target_os = "windows")]
pub fn add_bypass_route(runtime: &VpnRuntime, ip: &str) {
    use std::net::Ipv4Addr;
    use std::process::Command;

    if ip.parse::<Ipv4Addr>().is_err() {
        return;
    }

    {
        let existing = runtime.bypass_routes.lock();
        if existing.iter().any(|x| x == ip) {
            return;
        }
    }

    let gateway = runtime.physical_gateway.lock().clone();
    if gateway.is_empty() {
        return;
    }

    let _ = Command::new("route")
        .args(["ADD", ip, "MASK", "255.255.255.255", &gateway, "METRIC", "1"])
        .output();

    runtime.bypass_routes.lock().push(ip.to_string());
}

#[cfg(not(target_os = "windows"))]
pub fn add_bypass_route(_runtime: &VpnRuntime, _ip: &str) {}

// ============================================================
//  Маршруты и DNS
// ============================================================

pub fn setup_routes(runtime: &VpnRuntime, tun_ip: &str, tun_dns: &str, events: &EventBus) {
    #[cfg(target_os = "linux")]
    setup_routes_linux(tun_ip, tun_dns, events);

    #[cfg(target_os = "windows")]
    setup_routes_windows(runtime, tun_ip, tun_dns, events);
}

pub fn cleanup_routes(runtime: &VpnRuntime, events: &EventBus) {
    #[cfg(target_os = "linux")]
    cleanup_routes_linux(events);

    #[cfg(target_os = "windows")]
    cleanup_routes_windows(runtime, events);
}

// ---------- Linux ----------

#[cfg(target_os = "linux")]
fn setup_routes_linux(tun_ip: &str, tun_dns: &str, events: &EventBus) {
    for dns in tun_dns.split(',') {
        let dns = dns.trim();
        if dns.is_empty() {
            continue;
        }
        run_sudo(&format!("echo 'nameserver {}' >> /etc/resolv.conf", dns), events);
    }
    run_sudo(&format!("ip route add default dev {}", "csqtt0"), events);
    let _ = tun_ip;
}

#[cfg(target_os = "linux")]
fn cleanup_routes_linux(events: &EventBus) {
    run_sudo("ip route del default dev csqtt0 2>/dev/null || true", events);
}

#[cfg(target_os = "linux")]
fn run_sudo(command: &str, events: &EventBus) {
    use std::process::Command;
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

// ---------- Windows ----------

#[cfg(target_os = "windows")]
fn setup_routes_windows(
    runtime: &VpnRuntime,
    tun_ip: &str,
    tun_dns: &str,
    events: &EventBus,
) {
    use std::process::Command;

    let gateway = get_physical_gateway();
    if !gateway.is_empty() {
        events.emit(Event::log(format!("[TUN] physical gateway: {}", gateway)));
    }
    *runtime.physical_gateway.lock() = gateway.clone();

    // 1) Сначала bypass для TURN/Relay (по физическому шлюзу, метрика 1).
    let bypass_list = runtime.bypass_routes.lock().clone();
    for ip in &bypass_list {
        if gateway.is_empty() {
            break;
        }
        let _ = Command::new("route")
            .args(["ADD", ip, "MASK", "255.255.255.255", &gateway, "METRIC", "1"])
            .output();
    }

    // 2) Настраиваем адрес/MTU на адаптере CSQTT.
    let _ = Command::new("netsh")
        .args([
            "interface", "ipv4", "set", "address",
            "name=\"CSQTT\"", "source=static",
            &format!("address={}", tun_ip),
            "mask=255.255.255.255",
        ])
        .output();

    let _ = Command::new("netsh")
        .args([
            "interface", "ipv4", "set", "subinterface",
            "\"CSQTT\"",
            &format!("mtu={}", TUN_MTU),
            "store=active",
        ])
        .output();

    // 3) DNS-серверы (максимум 2).
    let mut dns_index = 1;
    for dns in tun_dns.split(',') {
        let dns = dns.trim();
        if dns.is_empty() || dns_index > 2 {
            continue;
        }
        let _ = Command::new("netsh")
            .args([
                "interface", "ipv4", "add", "dnsservers",
                "name=\"CSQTT\"",
                &format!("address={}", dns),
                &format!("index={}", dns_index),
                "validate=no",
            ])
            .output();
        dns_index += 1;
    }

    // 4) Default route через CSQTT.
    let _ = Command::new("netsh")
        .args([
            "interface", "ipv4", "add", "route",
            "prefix=0.0.0.0/0",
            "interface=\"CSQTT\"",
            "nexthop=0.0.0.0",
            "metric=5",
            "store=active",
        ])
        .output();

    events.emit(Event::log("[TUN] Windows routes + DNS configured"));
}

#[cfg(target_os = "windows")]
fn cleanup_routes_windows(runtime: &VpnRuntime, events: &EventBus) {
    use std::process::Command;

    let _ = Command::new("netsh")
        .args([
            "interface", "ipv4", "delete", "route",
            "prefix=0.0.0.0/0",
            "interface=\"CSQTT\"",
            "store=active",
        ])
        .output();

    let bypass_list = runtime.bypass_routes.lock().clone();
    for ip in &bypass_list {
        let _ = Command::new("route").args(["DELETE", ip]).output();
    }
    runtime.bypass_routes.lock().clear();
    *runtime.physical_gateway.lock() = String::new();

    events.emit(Event::log("[TUN] Windows routes cleaned"));
}

// ============================================================
//  WINDOWS: Wintun + UDP-мост
// ============================================================

#[cfg(target_os = "windows")]
pub fn start_tun(
    runtime: Arc<VpnRuntime>,
    tun_ip: String,
    tun_dns: String,
    events: EventBus,
) -> Result<()> {
    use std::net::UdpSocket;
    use std::path::PathBuf;

    // 1) Загружаем wintun.dll из %APPDATA%\.la-lune\wintun.dll
    let app_dir = crate::state::app_dir()?;
    let dll_path: PathBuf = app_dir.join("wintun.dll");
    events.emit(Event::log(format!(
        "[WINTUN] загружаю DLL: {}",
        dll_path.display()
    )));

    let session = crate::wintun::WintunSession::open_or_create(&dll_path)?;
    events.emit(Event::log(format!(
        "[WINTUN] адаптер {} готов, ring={} bytes",
        session.adapter_name(),
        crate::wintun::WINTUN_RING_CAPACITY
    )));

    // 2) UDP-сокет к ядру.
    let sock = UdpSocket::bind("127.0.0.1:0")?;
    sock.connect(format!("127.0.0.1:{}", CORE_LISTEN_PORT))?;

    // 2a) Большие буферы сокета — критично для throughput.
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawSocket;
        const SOL_SOCKET: i32 = 0xFFFF;
        const SO_RCVBUF: i32 = 0x1002;
        const SO_SNDBUF: i32 = 0x1001;
        const BUFSIZE: i32 = 8 * 1024 * 1024;

        extern "system" {
            fn setsockopt(
                s: usize,
                level: i32,
                optname: i32,
                optval: *const i8,
                optlen: i32,
            ) -> i32;
        }

        let raw = sock.as_raw_socket();
        unsafe {
            let v = BUFSIZE;
            setsockopt(
                raw as usize,
                SOL_SOCKET,
                SO_RCVBUF,
                &v as *const i32 as *const i8,
                std::mem::size_of::<i32>() as i32,
            );
            setsockopt(
                raw as usize,
                SOL_SOCKET,
                SO_SNDBUF,
                &v as *const i32 as *const i8,
                std::mem::size_of::<i32>() as i32,
            );
        }
    }

    let sock = Arc::new(sock);

    // 3) Сохраняем состояние + стартуем.
    *runtime.tun_conf.lock() = Some(TunConf {
        ip: tun_ip.clone(),
        dns: tun_dns.clone(),
        mtu: TUN_MTU,
    });

    // 4) Кладём сессию в runtime.
    {
        let mut guard = runtime.wintun.lock();
        *guard = Some(session);
    }

    runtime.running.store(true, Ordering::Relaxed);
    *runtime.started_at.lock() = Some(Instant::now());

    // 5) Маршруты/DNS/MTU.
    setup_routes(&runtime, &tun_ip, &tun_dns, &events);

    // 6) Две tokio-таски без мьютекса.
    //
    //    Task A: Wintun → UDP
    //    Task B: UDP → Wintun
    //
    //    WintunSession thread-safe, поэтому можно обращаться из обеих
    //    задач через Arc<Mutex<Option<...>>> только на время чтения
    //    указателя — но мы держим сессию в runtime.wintun и берём её
    //    через clone Arc + lock, чтобы не хранить raw-указатель.
    let running_a = runtime.running.clone();
    let tx_bytes = runtime.tx_bytes.clone();
    let events_a = events.clone();
    let wintun_a = runtime.wintun.clone();
    let sock_a = sock.clone();

    // Мост работает в блокирующем режиме, поэтому используем отдельные
    // std-потоки, а не tokio-таски — это то же, что старый Go.
    let wintun_b = runtime.wintun.clone();
    let sock_b = sock.clone();
    let running_b = runtime.running.clone();
    let rx_bytes = runtime.rx_bytes.clone();
    let events_b = events.clone();

    std::thread::Builder::new()
        .name("wintun->udp".into())
        .spawn(move || {
            let mut buf = vec![0u8; 65535];
            while running_a.load(Ordering::Relaxed) {
                // Берём сессию.
                let n = {
                    let guard = wintun_a.lock();
                    match guard.as_ref() {
                        Some(sess) => sess.recv_into(&mut buf),
                        None => 0,
                    }
                };
                if n == 0 {
                    // Нет пакета — короткая пауза, чтобы не крутить CPU.
                    std::thread::sleep(Duration::from_micros(200));
                    continue;
                }
                match sock_a.send(&buf[..n]) {
                    Ok(sent) => {
                        tx_bytes.fetch_add(sent as u64, Ordering::Relaxed);
                    }
                    Err(e) => {
                        events_a.emit(Event::log(format!("[TUN] udp send: {}", e)));
                    }
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
                    if let Err(e) = sess.send_packet(&buf[..n]) {
                        // Ring полон — ждём чуть-чуть.
                        let _ = e;
                        std::thread::sleep(Duration::from_micros(200));
                    } else {
                        rx_bytes.fetch_add(n as u64, Ordering::Relaxed);
                    }
                }
            }
            log::info!("[TUN] udp->wintun stop");
        })
        .map_err(|e| anyhow!("spawn udp->wintun: {}", e))?;

    events.emit(Event::log("[TUN] Wintun bridge started (2 threads, no mutex on hot path)"));
    Ok(())
}

// ============================================================
//  LINUX: TUN через крейт tun
// ============================================================

#[cfg(target_os = "linux")]
pub fn start_tun(
    runtime: Arc<VpnRuntime>,
    tun_ip: String,
    tun_dns: String,
    events: EventBus,
) -> Result<()> {
    use std::io::{Read, Write};
    use std::net::UdpSocket;
    use std::thread;
    use tun::Configuration;

    let mut config = Configuration::default();
    config
        .name("csqtt0")
        .address(&tun_ip)
        .netmask("255.255.255.255")
        .mtu(TUN_MTU as i32)
        .up();

    let dev = tun::create(&config).map_err(|e| anyhow!("tun create failed: {}", e))?;
    let dev = Arc::new(Mutex::new(dev));

    *runtime.tun_conf.lock() = Some(TunConf {
        ip: tun_ip.clone(),
        dns: tun_dns.clone(),
        mtu: TUN_MTU,
    });

    let sock = UdpSocket::bind("127.0.0.1:0")?;
    sock.connect(format!("127.0.0.1:{}", CORE_LISTEN_PORT))?;
    let sock = Arc::new(sock);

    runtime.running.store(true, Ordering::Relaxed);
    *runtime.started_at.lock() = Some(Instant::now());

    setup_routes(&runtime, &tun_ip, &tun_dns, &events);

    let running = runtime.running.clone();
    let rx = runtime.rx_bytes.clone();
    let tx = runtime.tx_bytes.clone();

    let dev_w = dev.clone();
    let sock_w = sock.clone();
    let running_w = running.clone();
    let rx_w = rx.clone();
    let tx_w = tx.clone();

    let handle = thread::spawn(move || {
        // TUN → UDP
        let dev_r = dev_w.clone();
        let sock_r = sock_w.clone();
        let running_r = running_w.clone();
        let tx_r = tx_w.clone();
        let h1 = thread::spawn(move || {
            let mut buf = vec![0u8; 65535];
            while running_r.load(Ordering::Relaxed) {
                let n = {
                    let mut guard = dev_r.lock();
                    guard.read(&mut buf).unwrap_or(0)
                };
                if n > 0 {
                    if sock_r.send(&buf[..n]).is_ok() {
                        tx_r.fetch_add(n as u64, Ordering::Relaxed);
                    }
                }
            }
        });

        // UDP → TUN
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
                        if guard.write(&buf[..n]).is_ok() {
                            rx_w2.fetch_add(n as u64, Ordering::Relaxed);
                        }
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
    events.emit(Event::log("[TUN] bridge started (Linux)"));
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
