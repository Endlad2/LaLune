// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// OpenWRT VPN runtime. The backend owns a dedicated TUN (lalune0). Router and
// LAN traffic are selected with iptables marks and policy-routed into that TUN;
// the core process itself runs under a dedicated UID and always stays on the
// physical/main route, preventing a VPN recursion loop.

use anyhow::{bail, Context, Result};
use parking_lot::Mutex;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
#[cfg(target_has_atomic = "64")]
use std::sync::atomic::AtomicU64;
#[cfg(not(target_has_atomic = "64"))]
use portable_atomic::AtomicU64;
use std::sync::Arc;
use std::time::Instant;

use crate::events::{Event, EventBus};

pub const CORE_LISTEN_PORT: u16 = 52230;
pub const TUN_NAME: &str = "lalune0";
pub const TUN_MTU: u16 = 1300;
pub const DEFAULT_TUN_IP: &str = "10.66.67.12";
pub const DEFAULT_DNS: &str = "8.8.8.8,8.8.4.4";

const ROUTE_TABLE: &str = "10620";
const UID_RULE_PRIORITY: &str = "10620";
const MARK_RULE_PRIORITY: &str = "10622";
const VPN_MARK: &str = "0x1062/0xffff";
const OUTPUT_CHAIN: &str = "LALUNE_OUTPUT";
const PREROUTING_CHAIN: &str = "LALUNE_PREROUTING";
const NAT_CHAIN: &str = "LALUNE_NAT";

const LOCAL_DESTINATIONS: &[&str] = &[
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "224.0.0.0/4",
    "240.0.0.0/4",
];

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
    pub connecting: AtomicBool,
    pub rx_bytes: Arc<AtomicU64>,
    pub tx_bytes: Arc<AtomicU64>,
    pub started_at: Arc<Mutex<Option<Instant>>>,
    pub tun_conf: Arc<Mutex<Option<TunConf>>>,
    pub handle: Mutex<Option<crate::linux_tun::Session>>,
    routing: Mutex<Option<OpenWrtRouting>>,
    pub core_uid: AtomicU32,
    pub operation: tokio::sync::Mutex<()>,
    pub watchdog: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl VpnRuntime {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            connecting: AtomicBool::new(false),
            rx_bytes: Arc::new(AtomicU64::new(0)),
            tx_bytes: Arc::new(AtomicU64::new(0)),
            started_at: Arc::new(Mutex::new(None)),
            tun_conf: Arc::new(Mutex::new(None)),
            handle: Mutex::new(None),
            routing: Mutex::new(None),
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
        // Remove policy routing/iptables first so no new packet is sent to a
        // TUN that is about to disappear.
        let routing = { self.routing.lock().take() };
        drop(routing);
        let session = { self.handle.lock().take() };
        if let Some(session) = session { session.stop().await; }
        *self.started_at.lock() = None;
        *self.tun_conf.lock() = None;
    }
}

pub fn start_tun(runtime: Arc<VpnRuntime>, tun_ip: String, tun_dns: String, events: EventBus) -> Result<()> {
    let uid = runtime.core_uid.load(Ordering::Acquire);
    if uid == 0 {
        bail!("Не определён UID ядра; безопасная маршрутизация OpenWRT невозможна");
    }

    // linux_tun only creates the fd/interface and UDP bridge here. OpenWRT
    // installs its own iptables + fwmark policy below instead of replacing the
    // system default route.
    let session = crate::linux_tun::Session::start(
        TUN_NAME,
        &tun_ip,
        &tun_dns,
        TUN_MTU,
        CORE_LISTEN_PORT,
        uid,
        runtime.running.clone(),
        runtime.rx_bytes.clone(),
        runtime.tx_bytes.clone(),
        events.clone(),
        false,
        Vec::new(),
    )?;

    let routing = match OpenWrtRouting::install(TUN_NAME, &tun_dns, uid, events.clone()) {
        Ok(routing) => routing,
        Err(error) => {
            drop(session);
            runtime.running.store(false, Ordering::Release);
            return Err(error).context("Настройка OpenWRT iptables/policy routing");
        }
    };

    *runtime.routing.lock() = Some(routing);
    *runtime.handle.lock() = Some(session);
    *runtime.started_at.lock() = Some(Instant::now());
    *runtime.tun_conf.lock() = Some(TunConf { ip: tun_ip.clone(), dns: tun_dns.clone(), mtu: TUN_MTU });
    events.emit(Event::named("tun_ready", serde_json::json!({
        "ip": tun_ip,
        "dns": tun_dns,
        "mtu": TUN_MTU,
        "interface": TUN_NAME,
        "routing": "iptables-fwmark",
        "mark": VPN_MARK,
        "table": ROUTE_TABLE,
    })));
    events.emit(Event::log(format!(
        "[TUN] {} ready; iptables mark={} -> table={} -> {}",
        TUN_NAME, VPN_MARK, ROUTE_TABLE, TUN_NAME
    )));
    Ok(())
}

struct OpenWrtRouting {
    name: String,
    uid: u32,
    dns: Option<(PathBuf, Vec<u8>, Vec<u8>)>,
    output_chain: bool,
    prerouting_chain: bool,
    nat_chain: bool,
    output_jump: bool,
    prerouting_jump: bool,
    nat_jump: bool,
    forward_out: bool,
    forward_in: bool,
    fw4_handles: Vec<u64>,
    uid_rule: bool,
    mark_rule: bool,
    route: bool,
    events: EventBus,
}

impl OpenWrtRouting {
    fn install(name: &str, dns: &str, uid: u32, events: EventBus) -> Result<Self> {
        if unsafe { libc::geteuid() } != 0 {
            bail!("OpenWRT VPN требует root/CAP_NET_ADMIN");
        }
        require_program("ip")?;
        require_iptables()?;

        cleanup_legacy_policy(&events);
        cleanup_stale_chains(name, &events);
        ensure_route_slots_free()?;
        let wan = physical_default_dev()?;

        let mut routing = Self {
            name: name.into(), uid, dns: None,
            output_chain: false, prerouting_chain: false, nat_chain: false,
            output_jump: false, prerouting_jump: false, nat_jump: false,
            forward_out: false, forward_in: false, fw4_handles: Vec::new(),
            uid_rule: false, mark_rule: false, route: false,
            events,
        };

        routing.create_chain("mangle", OUTPUT_CHAIN)?;
        routing.output_chain = true;
        routing.create_chain("mangle", PREROUTING_CHAIN)?;
        routing.prerouting_chain = true;
        routing.create_chain("nat", NAT_CHAIN)?;
        routing.nat_chain = true;

        for destination in LOCAL_DESTINATIONS {
            iptables(&["-t", "mangle", "-A", OUTPUT_CHAIN, "-d", *destination, "-j", "RETURN"])?;
        }
        iptables(&[
            "-t", "mangle", "-A", OUTPUT_CHAIN,
            "-j", "MARK", "--set-xmark", VPN_MARK,
        ])?;

        iptables(&["-t", "mangle", "-A", PREROUTING_CHAIN, "-i", name, "-j", "RETURN"])?;
        iptables(&["-t", "mangle", "-A", PREROUTING_CHAIN, "-i", &wan, "-j", "RETURN"])?;
        for destination in LOCAL_DESTINATIONS {
            iptables(&["-t", "mangle", "-A", PREROUTING_CHAIN, "-d", *destination, "-j", "RETURN"])?;
        }
        iptables(&[
            "-t", "mangle", "-A", PREROUTING_CHAIN,
            "-j", "MARK", "--set-xmark", VPN_MARK,
        ])?;
        iptables(&["-t", "nat", "-A", NAT_CHAIN, "-j", "MASQUERADE"])?;

        // Table 10620 contains only the VPN default. The core UID has a higher
        // priority rule to main, so its transport can never recurse into lalune0.
        ip(&["-4", "route", "add", "default", "dev", name, "table", ROUTE_TABLE])?;
        routing.route = true;
        let uidrange = format!("{uid}-{uid}");
        ip(&[
            "-4", "rule", "add", "priority", UID_RULE_PRIORITY,
            "uidrange", &uidrange, "lookup", "main",
        ])?;
        routing.uid_rule = true;
        ip(&[
            "-4", "rule", "add", "priority", MARK_RULE_PRIORITY,
            "fwmark", VPN_MARK, "lookup", ROUTE_TABLE,
        ])?;
        routing.mark_rule = true;

        // Activate packet selection only after the policy table is ready.
        iptables(&["-t", "mangle", "-A", "OUTPUT", "-j", OUTPUT_CHAIN])?;
        routing.output_jump = true;
        iptables(&["-t", "mangle", "-A", "PREROUTING", "-j", PREROUTING_CHAIN])?;
        routing.prerouting_jump = true;
        iptables(&["-t", "nat", "-A", "POSTROUTING", "-o", name, "-j", NAT_CHAIN])?;
        routing.nat_jump = true;

        // Legacy firewall3/iptables path. On firewall4 we additionally insert
        // temporary accept rules into inet/fw4 below, because a separate nft
        // base chain can otherwise reject traffic to an unzoned TUN device.
        iptables(&["-t", "filter", "-I", "FORWARD", "1", "-o", name, "-j", "ACCEPT"])?;
        routing.forward_out = true;
        iptables(&["-t", "filter", "-I", "FORWARD", "1", "-i", name, "-j", "ACCEPT"])?;
        routing.forward_in = true;
        routing.fw4_handles = install_fw4_compat(name)?;

        routing.install_dns(dns)?;
        routing.events.emit(Event::log(format!(
            "[ROUTE] wan={wan}; core_uid={uid}; OUTPUT/PREROUTING -> mark {VPN_MARK}; NAT -> {name}"
        )));
        Ok(routing)
    }

    fn create_chain(&self, table: &str, chain: &str) -> Result<()> {
        iptables(&["-t", table, "-N", chain])
            .with_context(|| format!("Не удалось создать iptables chain {table}/{chain}"))
            .map(|_| ())
    }

    fn install_dns(&mut self, dns: &str) -> Result<()> {
        let installed = dns_content(dns)?;
        let path = PathBuf::from("/etc/resolv.conf");
        let previous = fs::read(&path).context("Чтение исходного /etc/resolv.conf")?;
        if let Err(error) = fs::write(&path, &installed) {
            let _ = fs::write(&path, &previous);
            return Err(error).context("Настройка DNS OpenWRT для VPN");
        }
        self.dns = Some((path, previous, installed));
        Ok(())
    }
}

impl Drop for OpenWrtRouting {
    fn drop(&mut self) {
        // Stop selecting packets first, then remove policy routes/chains.
        if self.output_jump {
            try_iptables(&["-t", "mangle", "-D", "OUTPUT", "-j", OUTPUT_CHAIN]);
        }
        if self.prerouting_jump {
            try_iptables(&["-t", "mangle", "-D", "PREROUTING", "-j", PREROUTING_CHAIN]);
        }
        if self.forward_in {
            try_iptables(&["-t", "filter", "-D", "FORWARD", "-i", &self.name, "-j", "ACCEPT"]);
        }
        if self.forward_out {
            try_iptables(&["-t", "filter", "-D", "FORWARD", "-o", &self.name, "-j", "ACCEPT"]);
        }
        for handle in self.fw4_handles.drain(..) {
            delete_fw4_handle(handle);
        }
        if self.nat_jump {
            try_iptables(&["-t", "nat", "-D", "POSTROUTING", "-o", &self.name, "-j", NAT_CHAIN]);
        }
        if self.mark_rule {
            try_ip(&["-4", "rule", "del", "priority", MARK_RULE_PRIORITY]);
        }
        if self.uid_rule {
            try_ip(&["-4", "rule", "del", "priority", UID_RULE_PRIORITY]);
        }
        if self.route {
            try_ip(&["-4", "route", "flush", "table", ROUTE_TABLE]);
        }
        if self.output_chain {
            try_iptables(&["-t", "mangle", "-F", OUTPUT_CHAIN]);
            try_iptables(&["-t", "mangle", "-X", OUTPUT_CHAIN]);
        }
        if self.prerouting_chain {
            try_iptables(&["-t", "mangle", "-F", PREROUTING_CHAIN]);
            try_iptables(&["-t", "mangle", "-X", PREROUTING_CHAIN]);
        }
        if self.nat_chain {
            try_iptables(&["-t", "nat", "-F", NAT_CHAIN]);
            try_iptables(&["-t", "nat", "-X", NAT_CHAIN]);
        }
        if let Some((path, previous, installed)) = &self.dns {
            if fs::read(path).ok().as_deref() == Some(installed.as_slice()) {
                if let Err(error) = fs::write(path, previous) {
                    self.events.emit(Event::error(format!("Не удалось восстановить DNS: {error}")));
                }
            }
        }
        self.events.emit(Event::log(format!(
            "[ROUTE] iptables/policy routing removed (core_uid={})",
            self.uid
        )));
    }
}

fn require_program(program: &str) -> Result<()> {
    let status = Command::new(program).arg("--version").output();
    if status.is_err() {
        bail!("Не найдена команда {program}; установщик OpenWRT должен поставить ip-full и iptables-nft");
    }
    Ok(())
}

fn run(program: &str, args: &[&str]) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("Не удалось запустить {program}"))?;
    if !output.status.success() {
        bail!(
            "{} {}: {}",
            program,
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn ip(args: &[&str]) -> Result<String> { run("ip", args) }

fn iptables_program() -> Option<&'static str> {
    for program in ["iptables", "iptables-nft"] {
        if Command::new(program).arg("--version").output().is_ok() {
            return Some(program);
        }
    }
    None
}

fn require_iptables() -> Result<()> {
    if iptables_program().is_none() {
        bail!("Не найдены iptables/iptables-nft; установите пакет iptables-nft");
    }
    Ok(())
}

fn iptables(args: &[&str]) -> Result<String> {
    let program = iptables_program().context("Не найдены iptables/iptables-nft")?;
    run(program, args)
}

fn try_ip(args: &[&str]) { let _ = Command::new("ip").args(args).output(); }
fn try_iptables(args: &[&str]) {
    if let Some(program) = iptables_program() {
        let _ = Command::new(program).args(args).output();
    }
}

fn chain_exists(table: &str, chain: &str) -> bool {
    iptables_program().is_some_and(|program| {
        Command::new(program)
            .args(["-t", table, "-S", chain])
            .output()
            .is_ok_and(|output| output.status.success())
    })
}

fn try_nft(args: &[&str]) { let _ = Command::new("nft").args(args).output(); }

fn delete_fw4_handle(handle: u64) {
    let handle = handle.to_string();
    try_nft(&["delete", "rule", "inet", "fw4", "forward", "handle", &handle]);
}

fn fw4_forward_exists() -> bool {
    Command::new("nft")
        .args(["list", "chain", "inet", "fw4", "forward"])
        .output()
        .is_ok_and(|output| output.status.success())
}

fn fw4_handles_with_prefix(prefix: &str) -> Vec<u64> {
    let Ok(output) = Command::new("nft")
        .args(["-a", "list", "chain", "inet", "fw4", "forward"])
        .output() else { return Vec::new() };
    if !output.status.success() { return Vec::new(); }
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines()
        .filter(|line| line.contains(prefix))
        .filter_map(|line| line.rsplit_once("handle ").and_then(|(_, handle)| handle.trim().parse().ok()))
        .collect()
}

fn install_fw4_compat(name: &str) -> Result<Vec<u64>> {
    if !fw4_forward_exists() { return Ok(Vec::new()); }

    // Remove rules left by a killed backend before creating the current set.
    for handle in fw4_handles_with_prefix("lalune-vpn-") {
        delete_fw4_handle(handle);
    }

    let rules: [(&str, Vec<&str>); 3] = [
        ("lalune-vpn-mark", vec!["meta", "mark", "&", "0xffff", "==", "0x1062", "accept"]),
        ("lalune-vpn-in", vec!["iifname", name, "accept"]),
        ("lalune-vpn-out", vec!["oifname", name, "accept"]),
    ];
    for (comment, expression) in rules {
        let mut args = vec!["insert", "rule", "inet", "fw4", "forward"];
        args.extend(expression);
        args.extend(["comment", comment]);
        if let Err(error) = run("nft", &args) {
            for handle in fw4_handles_with_prefix("lalune-vpn-") {
                delete_fw4_handle(handle);
            }
            return Err(error).with_context(|| format!("Не удалось разрешить {name} в firewall4"));
        }
    }

    let handles = fw4_handles_with_prefix("lalune-vpn-");
    if handles.len() != 3 {
        for handle in handles.iter().copied() {
            delete_fw4_handle(handle);
        }
        bail!("Не удалось подтвердить временные firewall4 rules для {name}");
    }
    Ok(handles)
}

fn cleanup_legacy_policy(events: &EventBus) {
    // Previous OpenWRT releases used linux_tun's three-rule full-tunnel setup:
    // 10620 uidrange -> main, 10621 main suppress default, 10622 -> table 10620.
    // A hard-killed backend could leave those rules behind after csqtt0 vanished.
    let Ok(rules) = ip(&["-N", "-4", "rule", "show"]) else { return };
    let legacy = rules.lines().any(|line| {
        line.trim_start().starts_with("10621:")
            && line.contains("lookup main")
            && line.contains("suppress_prefixlength 0")
    }) && rules.lines().any(|line| {
        line.trim_start().starts_with("10622:") && line.contains(&format!("lookup {ROUTE_TABLE}"))
    });
    if !legacy { return; }

    events.emit(Event::log("[ROUTE] removing legacy csqtt0 policy-routing state"));
    try_ip(&["-4", "rule", "del", "priority", "10622"]);
    try_ip(&["-4", "rule", "del", "priority", "10621"]);
    try_ip(&["-4", "rule", "del", "priority", "10620"]);
    try_ip(&["-4", "route", "flush", "table", ROUTE_TABLE]);
}

fn cleanup_stale_chains(name: &str, events: &EventBus) {
    let stale = chain_exists("mangle", OUTPUT_CHAIN)
        || chain_exists("mangle", PREROUTING_CHAIN)
        || chain_exists("nat", NAT_CHAIN);
    if !stale { return; }
    events.emit(Event::log("[ROUTE] removing stale LaLune iptables state"));
    for handle in fw4_handles_with_prefix("lalune-vpn-") {
        delete_fw4_handle(handle);
    }
    try_iptables(&["-t", "filter", "-D", "FORWARD", "-i", name, "-j", "ACCEPT"]);
    try_iptables(&["-t", "filter", "-D", "FORWARD", "-o", name, "-j", "ACCEPT"]);
    try_iptables(&["-t", "mangle", "-D", "OUTPUT", "-j", OUTPUT_CHAIN]);
    try_iptables(&["-t", "mangle", "-D", "PREROUTING", "-j", PREROUTING_CHAIN]);
    try_iptables(&["-t", "nat", "-D", "POSTROUTING", "-o", name, "-j", NAT_CHAIN]);
    for (table, chain) in [("mangle", OUTPUT_CHAIN), ("mangle", PREROUTING_CHAIN), ("nat", NAT_CHAIN)] {
        try_iptables(&["-t", table, "-F", chain]);
        try_iptables(&["-t", table, "-X", chain]);
    }
    try_ip(&["-4", "rule", "del", "priority", MARK_RULE_PRIORITY]);
    try_ip(&["-4", "rule", "del", "priority", UID_RULE_PRIORITY]);
    try_ip(&["-4", "route", "flush", "table", ROUTE_TABLE]);
}

fn ensure_route_slots_free() -> Result<()> {
    let rules = ip(&["-N", "-4", "rule", "show"])?;
    for line in rules.lines() {
        let priority = line.split(':').next().map(str::trim).unwrap_or("");
        if priority == UID_RULE_PRIORITY || priority == MARK_RULE_PRIORITY || line.contains(&format!("lookup {ROUTE_TABLE}")) {
            bail!("Таблица/приоритет policy routing LaLune уже занят: {line}");
        }
    }
    let table = ip(&["-4", "route", "show", "table", ROUTE_TABLE])?;
    if !table.trim().is_empty() {
        bail!("Таблица маршрутизации {ROUTE_TABLE} уже содержит маршруты");
    }
    Ok(())
}

fn physical_default_dev() -> Result<String> {
    let routes = ip(&["-4", "route", "show", "default"])?;
    for line in routes.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.first().copied() != Some("default") { continue; }
        if let Some(dev) = fields.windows(2).find(|pair| pair[0] == "dev").map(|pair| pair[1]) {
            return Ok(dev.to_string());
        }
    }
    bail!("Не найден физический IPv4 default route OpenWRT")
}

fn dns_content(dns: &str) -> Result<Vec<u8>> {
    let mut text = String::new();
    for address in dns.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let _: std::net::Ipv4Addr = address.parse().context("Некорректный IPv4 DNS")?;
        text.push_str(&format!("nameserver {address}\n"));
    }
    if text.is_empty() { bail!("Не указан DNS для TUN"); }
    Ok(text.into_bytes())
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
