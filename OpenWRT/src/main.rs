// owrt-client — LaLune клиент для OpenWRT (без SDK).
//
// Сборка:
//   cross build --release --target aarch64-unknown-linux-musl
//
// Команды:
//   owrt-client start        запустить ядро + TUN-демон в фоне (читает ./config)
//   owrt-client logs         показать лог ядра
//   owrt-client tun-logs     показать лог TUN-демона
//   owrt-client stop         остановить ядро и TUN-демон
//   owrt-client status       показать статус

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tun_rs::DeviceBuilder;

// ============================================================
//  Пути и константы
// ============================================================

const WORK_DIR: &str = "/tmp/owrt-client";
const CORE_LOG: &str = "core.log";
const TUN_LOG: &str = "tun.log";
const CORE_PID: &str = "core.pid";
const TUN_PID: &str = "tun.pid";
const CONFIG_FILE: &str = "config";

const CORE_URL_TEMPLATE: &str =
    "https://github.com/Endlad2/csqtt-core/releases/download/{VER}/{FILE}";
const PROXY_URL: &str = "http://31.77.148.203:8855/?url=";
const CORE_VERSION: &str = "2026.09.10.16.39";

#[cfg(target_arch = "aarch64")]
const CORE_FILENAME: &str = "client-linux-arm64";

#[cfg(target_arch = "arm")]
const CORE_FILENAME: &str = "client-linux-armv7";

#[cfg(target_arch = "x86_64")]
const CORE_FILENAME: &str = "client-linux-x86_64";

#[cfg(not(any(target_arch = "aarch64", target_arch = "arm", target_arch = "x86_64")))]
compile_error!("Unsupported architecture.");

const CORE_LISTEN_PORT: u16 = 52230;
const TUN_NAME: &str = "csqtt0";
const TUN_MTU: u16 = 1300;
const DEFAULT_TUN_IP: &str = "10.66.67.12";
const DEFAULT_DNS: &str = "8.8.8.8,8.8.4.4";

// ============================================================
//  Структуры
// ============================================================

#[derive(Debug, Clone)]
struct CsqttConfig {
    peer: String,
    password: String,
    hashes: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct Settings {
    #[serde(default = "default_workers", rename = "workersPerHash")]
    workers_per_hash: u32,
    #[serde(default = "default_obfs")]
    obfs: String,
    #[serde(default = "default_fingerprint")]
    fingerprint: String,
    #[serde(default = "default_client_ids", rename = "clientIds")]
    client_ids: String,
    #[serde(default = "default_vk_auth_mode", rename = "vkAuthMode")]
    vk_auth_mode: String,
    #[serde(default = "default_captcha_mode", rename = "captchaMode")]
    captcha_mode: String,
    #[serde(default, rename = "deviceId")]
    device_id: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            workers_per_hash: default_workers(),
            obfs: default_obfs(),
            fingerprint: default_fingerprint(),
            client_ids: default_client_ids(),
            vk_auth_mode: default_vk_auth_mode(),
            captcha_mode: default_captcha_mode(),
            device_id: uuid::Uuid::new_v4().to_string().replace('-', ""),
        }
    }
}

fn default_workers() -> u32 { 9 }
fn default_obfs() -> String { "video".into() }
fn default_fingerprint() -> String { "firefox".into() }
fn default_client_ids() -> String { "8202606,6287487".into() }
fn default_vk_auth_mode() -> String { "vkcalls".into() }
fn default_captcha_mode() -> String { "auto".into() }

// ============================================================
//  main
// ============================================================

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format_timestamp_millis()
        .init();

    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(String::as_str).unwrap_or("start");

    match cmd {
        "start" | "" => run_start(),
        "tun-daemon" => run_tun_daemon_entry(),
        "logs" => run_logs(),
        "tun-logs" => run_tun_logs(),
        "stop" => run_stop(),
        "status" => run_status(),
        "-h" | "--help" | "help" => { print_help(); Ok(()) }
        other => {
            eprintln!("Неизвестная команда: {}", other);
            print_help();
            std::process::exit(2);
        }
    }
}

fn print_help() {
    println!(
        r#"owrt-client — LaLune клиент для OpenWRT

Использование:
  owrt-client start        запустить ядро + TUN-демон в фоне
  owrt-client logs         показать лог ядра
  owrt-client tun-logs     показать лог TUN-демона
  owrt-client stop         остановить всё
  owrt-client status       показать статус

Файлы:
  ./config                csqtt:// ссылка рядом с бинарником
  {work}/core.log         лог ядра
  {work}/tun.log          лог TUN-демона
  {work}/core.pid         PID ядра
  {work}/tun.pid          PID TUN-демона
"#,
        work = WORK_DIR
    );
}

// ============================================================
//  start — запускает ядро и форкает TUN-демон
// ============================================================

fn run_start() -> Result<()> {
    let work = Path::new(WORK_DIR);
    fs::create_dir_all(work).context("не могу создать рабочую папку")?;

    let exe = std::env::current_exe().context("не могу получить путь к бинарнику")?;
    let exe_dir = exe.parent().ok_or_else(|| anyhow!("нет родительской папки"))?;
    let config_path = exe_dir.join(CONFIG_FILE);

    if !config_path.exists() {
        return Err(anyhow!(
            "файл конфига не найден: {}\nСоздайте его со ссылкой csqtt://...",
            config_path.display()
        ));
    }

    let link = fs::read_to_string(&config_path)
        .with_context(|| format!("не могу прочитать {}", config_path.display()))?;
    let link = link.trim();
    if link.is_empty() {
        return Err(anyhow!("файл {} пустой", config_path.display()));
    }

    let cfg = parse_csqtt_link(link)?;
    log::info!(
        "Конфиг: peer={} hashes={} (password скрыт)",
        cfg.peer,
        cfg.hashes.split(',').count()
    );

    // Убиваем старые процессы
    kill_by_pid(work.join(CORE_PID))?;
    kill_by_pid(work.join(TUN_PID))?;

    // Скачиваем ядро
    let core_path = work.join(CORE_FILENAME);
    if !core_path.exists() {
        log::info!("Скачиваю ядро {} ...", CORE_FILENAME);
        download_core(&core_path)?;
    } else {
        log::info!("Ядро уже есть: {}", core_path.display());
    }

    // Настройки
    let settings = load_or_default_settings();

    // ===== 1) Запускаем ядро =====
    let core_log_path = work.join(CORE_LOG);
    let core_log = OpenOptions::new()
        .create(true).write(true).truncate(true)
        .open(&core_log_path).context("открытие core.log")?;
    let core_log_err = core_log.try_clone()?;

    let mut cmd = Command::new(&core_path);
    cmd.arg("-peer").arg(&cfg.peer)
        .arg("-password").arg(&cfg.password)
        .arg("-vk").arg(&cfg.hashes)
        .arg("-n").arg(total_workers(&settings, &cfg.hashes).to_string())
        .arg("-listen").arg(format!("127.0.0.1:{}", CORE_LISTEN_PORT))
        .arg("-obfs").arg(&settings.obfs)
        .arg("-fingerprint").arg(&settings.fingerprint)
        .arg("-client-ids").arg(&settings.client_ids)
        .arg("-vk-auth-mode").arg(&settings.vk_auth_mode)
        .arg("-captcha-mode").arg(&settings.captcha_mode)
        .arg("-device-id").arg(&settings.device_id)
        .stdin(Stdio::null())
        .stdout(Stdio::from(core_log))
        .stderr(Stdio::from(core_log_err));

    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let core_child = cmd.spawn().context("spawn ядра")?;
    let core_pid = core_child.id();
    write_pid(work.join(CORE_PID), core_pid)?;
    log::info!("Ядро запущено, PID={}", core_pid);

    // ===== 2) Запускаем TUN-демон в фоне =====
    // Перезапускаем сами себя с аргументом tun-daemon, чтобы отдельный процесс
    // занимался TUN'ом и не мешал основному.
    let tun_log_path = work.join(TUN_LOG);
    let tun_log = OpenOptions::new()
        .create(true).write(true).truncate(true)
        .open(&tun_log_path).context("открытие tun.log")?;
    let tun_log_err = tun_log.try_clone()?;

    let mut tun_cmd = Command::new(&exe);
    tun_cmd.arg("tun-daemon")
        .stdin(Stdio::null())
        .stdout(Stdio::from(tun_log))
        .stderr(Stdio::from(tun_log_err));

    unsafe {
        tun_cmd.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let tun_child = tun_cmd.spawn().context("spawn tun-daemon")?;
    let tun_pid = tun_child.id();
    write_pid(work.join(TUN_PID), tun_pid)?;
    log::info!("TUN-демон запущен, PID={}", tun_pid);

    log::info!("Готово. Ядро: core.log, TUN: tun.log");
    Ok(())
}

// ============================================================
//  TUN-демон (запускается как ./owrt-client tun-daemon)
// ============================================================

fn run_tun_daemon_entry() -> Result<()> {
    let work = Path::new(WORK_DIR);
    fs::create_dir_all(work)?;

    let log_path = work.join(TUN_LOG);
    // Логи этого процесса уже идут в tun.log через Stdio::from в родителе,
    // но env_logger пишет в stderr — так что тоже туда попадёт.

    log::info!("=== TUN-демон запущен ===");
    log::info!("Ждём появления [СТАТИСТИКА] в core.log...");

    run_tun_daemon(work, &log_path)
}

fn run_tun_daemon(work: &Path, _log_path: &Path) -> Result<()> {
    let core_log = work.join(CORE_LOG);

    // Ждём появления файла
    let mut waited = 0u64;
    while !core_log.exists() {
        if waited > 10_000 {
            return Err(anyhow!("core.log так и не появился"));
        }
        thread::sleep(Duration::from_millis(500));
        waited += 500;
    }

    // Читаем core.log построчно, реагируем на две вещи:
    //   1) TUNCONF:IP:DNS или "Tunnel IP: ... DNS: ..." — запоминаем
    //   2) [СТАТИСТИКА] Активных: N | Трафик: M с N>0 — поднимаем TUN
    let mut last_offset: u64 = 0;
    let mut detected_tun_ip: Option<String> = None;
    let mut detected_dns: Option<String> = None;
    let mut tun_up = false;

    // Таймаут ожидания N>0 — 90 секунд
    let start = std::time::Instant::now();
    let timeout = Duration::from_secs(90);

    loop {
        if start.elapsed() > timeout {
            log::warn!("Таймаут ожидания N>0 (90с). TUN не поднят.");
            return Ok(());
        }

        // Открываем лог, читаем с последнего смещения
        if let Ok(mut f) = File::open(&core_log) {
            let size = f.metadata().map(|m| m.len()).unwrap_or(0);
            if size > last_offset {
                f.seek(std::io::SeekFrom::Start(last_offset))?;
                let mut reader = BufReader::new(f);
                let mut line = String::new();

                while reader.read_line(&mut line).unwrap_or(0) > 0 {
                    let l = line.trim_end_matches(['\r', '\n']);
                    process_core_line(
                        l,
                        &mut detected_tun_ip,
                        &mut detected_dns,
                        &mut tun_up,
                    );
                    line.clear();
                }

                last_offset = size;
            }
        }

        // Если TUN ещё не поднят и есть IP/DNS + статистика с N>0 — поднимаем
        if !tun_up {
            if let (Some(ip), Some(_dns)) = (&detected_tun_ip, &detected_dns) {
                log::info!("Данные для TUN получены: IP={}", ip);
                match build_tun(ip) {
                    Ok(device) => {
                        log::info!("TUN {} поднят", TUN_NAME);
                        if let Err(e) = run_bridge(device) {
                            log::error!("Мост TUN↔UDP упал: {}", e);
                        }
                        tun_up = true;
                    }
                    Err(e) => {
                        log::error!("Не удалось создать TUN: {}", e);
                    }
                }
            }
        }

        // Проверяем, живо ли ядро: если core.log не растёт и процесс мёртв — выходим
        if tun_up && !core_alive(work) {
            log::warn!("Ядро завершилось, останавливаю TUN-мост");
            return Ok(());
        }

        thread::sleep(Duration::from_millis(500));
    }
}

fn process_core_line(
    line: &str,
    tun_ip: &mut Option<String>,
    tun_dns: &mut Option<String>,
    tun_up: &mut bool,
) {
    if line.is_empty() {
        return;
    }

    log::debug!("[core] {}", line);

    // TUNCONF:IP:DNS
    if let Some(rest) = line.strip_prefix("TUNCONF:") {
        let parts: Vec<&str> = rest.split(':').collect();
        if parts.len() >= 2 {
            *tun_ip = Some(parts[0].trim().to_string());
            *tun_dns = Some(parts[1].trim().to_string());
            log::info!("TUNCONF: IP={} DNS={}", parts[0], parts[1]);
        }
    }

    // Tunnel IP: 10.66.67.11/32 | DNS: 77.88.8.8,77.88.8.1
    if line.contains("Tunnel IP:") && line.contains("DNS:") {
        if let Some(ip_start) = line.find("Tunnel IP:") {
            let after_ip = &line[ip_start + "Tunnel IP:".len()..];
            if let Some(pipe) = after_ip.find('|') {
                let ip_part = after_ip[..pipe].trim();
                let ip_clean = ip_part.split('/').next().unwrap_or("").trim();
                if !ip_clean.is_empty() {
                    *tun_ip = Some(ip_clean.to_string());
                }
                let after_dns = &after_ip[pipe + 1..];
                if let Some(dns_idx) = after_dns.find("DNS:") {
                    let dns_part = after_dns[dns_idx + 4..].trim();
                    let dns_clean: String = dns_part
                        .split(|c: char| c == ' ' || c == '|')
                        .next()
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    if !dns_clean.is_empty() {
                        *tun_dns = Some(dns_clean);
                    }
                }
            }
        }
    }

    // [СТАТИСТИКА] Активных: N | Трафик: M
    // Регекс вручную, чтобы не тянуть regex-крейт
    if line.contains("[СТАТИСТИКА]") && line.contains("Активных:") {
        if let Some(active_str) = extract_after(line, "Активных:") {
            if let Ok(n) = active_str.parse::<u32>() {
                if n > 0 && !*tun_up {
                    log::info!("СТАТИСТИКА: Активных={} — готовы поднимать TUN", n);
                    // Не поднимаем сами здесь — установим флаг, run_tun_daemon
                    // поднимет TUN когда увидит, что есть и IP, и N>0.
                    // Если IP ещё нет — ждём.
                    if tun_ip.is_some() {
                        // OK, run_tun_daemon подхватит
                    }
                }
            }
        }
    }
}

fn extract_after<'a>(line: &'a str, marker: &str) -> Option<&'a str> {
    let idx = line.find(marker)?;
    let after = &line[idx + marker.len()..];
    let trimmed = after.trim_start();
    let end = trimmed
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(trimmed.len());
    if end == 0 { None } else { Some(&trimmed[..end]) }
}

// ============================================================
//  TUN + UDP-мост
// ============================================================

fn build_tun(tun_ip: &str) -> Result<tun_rs::SyncDevice> {
    let dev = DeviceBuilder::new()
        .name(TUN_NAME)
        .ipv4(tun_ip, 32, None)
        .mtu(TUN_MTU)
        .build_sync()
        .context("DeviceBuilder::build_sync")?;
    Ok(dev)
}

fn run_bridge(dev: tun_rs::SyncDevice) -> Result<()> {
    // UDP-соединение к ядру
    use std::net::UdpSocket;
    let sock = UdpSocket::bind("127.0.0.1:0")?;
    sock.connect(format!("127.0.0.1:{}", CORE_LISTEN_PORT))?;
    let sock = Arc::new(sock);

    let running = Arc::new(AtomicBool::new(true));

    // Поток TUN → UDP
    let dev_w = Arc::new(dev);
    let dev_w2 = dev_w.clone();
    let sock_w = sock.clone();
    let running_w = running.clone();
    thread::spawn(move || {
        let mut buf = vec![0u8; 65535];
        while running_w.load(Ordering::Relaxed) {
            match dev_w2.recv(&mut buf) {
                Ok(n) if n > 0 => {
                    if let Err(e) = sock_w.send(&buf[..n]) {
                        log::warn!("udp send: {}", e);
                    }
                }
                Ok(_) => {}
                Err(e) => {
                    log::warn!("tun recv: {}", e);
                    break;
                }
            }
        }
        running_w.store(false, Ordering::Relaxed);
    });

    // Поток UDP → TUN
    let dev_r = dev_w.clone();
    let sock_r = sock.clone();
    let running_r = running.clone();
    thread::spawn(move || {
        let mut buf = vec![0u8; 65535];
        while running_r.load(Ordering::Relaxed) {
            match sock_r.recv(&mut buf) {
                Ok(n) if n > 0 => {
                    if let Err(e) = dev_r.send(&buf[..n]) {
                        log::warn!("tun send: {}", e);
                    }
                }
                Ok(_) => {}
                Err(e) => {
                    log::warn!("udp recv: {}", e);
                    break;
                }
            }
        }
        running_r.store(false, Ordering::Relaxed);
    });

    // Главный цикл: ждём, пока running не сбросится
    while running.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(500));
    }

    log::info!("TUN-мост остановлен");
    Ok(())
}

// ============================================================
//  Утилиты
// ============================================================

fn run_logs() -> Result<()> {
    print_file(Path::new(WORK_DIR).join(CORE_LOG))
}

fn run_tun_logs() -> Result<()> {
    print_file(Path::new(WORK_DIR).join(TUN_LOG))
}

fn print_file(p: PathBuf) -> Result<()> {
    if !p.exists() {
        eprintln!("Файл не найден: {}", p.display());
        std::process::exit(1);
    }
    let f = File::open(&p)?;
    let reader = BufReader::new(f);
    for line in reader.lines().map_while(Result::ok) {
        println!("{}", line);
    }
    Ok(())
}

fn run_stop() -> Result<()> {
    let work = Path::new(WORK_DIR);
    kill_by_pid(work.join(TUN_PID))?;
    kill_by_pid(work.join(CORE_PID))?;
    let _ = fs::remove_file(work.join(TUN_PID));
    let _ = fs::remove_file(work.join(CORE_PID));
    // Убираем TUN-интерфейс, если остался
    let _ = Command::new("ip").args(["link", "del", TUN_NAME]).status();
    println!("Остановлено");
    Ok(())
}

fn run_status() -> Result<()> {
    let work = Path::new(WORK_DIR);
    for (name, pid_file) in [("Ядро", CORE_PID), ("TUN", TUN_PID)] {
        match read_pid(work.join(pid_file)) {
            Some(pid) => {
                let alive = unsafe { libc::kill(pid, 0) } == 0;
                if alive {
                    println!("{}: запущен, PID={}", name, pid);
                } else {
                    println!("{}: PID-файл есть ({}), но процесс мёртв", name, pid);
                }
            }
            None => println!("{}: не запущен", name),
        }
    }
    Ok(())
}

fn core_alive(work: &Path) -> bool {
    match read_pid(work.join(CORE_PID)) {
        Some(pid) => unsafe { libc::kill(pid, 0) == 0 },
        None => false,
    }
}

fn kill_by_pid(pid_file: PathBuf) -> Result<()> {
    if let Some(pid) = read_pid(pid_file) {
        unsafe { libc::kill(pid, libc::SIGTERM) };
        thread::sleep(Duration::from_millis(300));
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
    Ok(())
}

fn write_pid(path: PathBuf, pid: u32) -> Result<()> {
    let mut f = File::create(path)?;
    writeln!(f, "{}", pid)?;
    Ok(())
}

fn read_pid(path: PathBuf) -> Option<i32> {
    let s = fs::read_to_string(path).ok()?;
    s.trim().parse().ok()
}

// ============================================================
//  Парсинг csqtt://
// ============================================================

fn parse_csqtt_link(link: &str) -> Result<CsqttConfig> {
    let link = link.trim();
    if !link.to_lowercase().starts_with("csqtt://") {
        return Err(anyhow!("ссылка должна начинаться с csqtt://"));
    }
    let rest = &link["csqtt://".len()..];

    if let Some(query) = rest.strip_prefix("connect?") {
        let params = parse_query(query);
        if params.get("v").map(String::as_str) != Some("2") {
            return Err(anyhow!("неподдерживаемая версия ссылки"));
        }
        let host = params.get("host").ok_or_else(|| anyhow!("нет host"))?;
        let port = params.get("peer").ok_or_else(|| anyhow!("нет peer"))?;
        let password = params.get("password").ok_or_else(|| anyhow!("нет password"))?;
        let hashes_raw = params.get("hashes").cloned().unwrap_or_default();
        let hashes: Vec<String> = hashes_raw
            .split('+').map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()).collect();
        if hashes.is_empty() {
            return Err(anyhow!("нет hashes"));
        }
        return Ok(CsqttConfig {
            peer: format!("{}:{}", host, port),
            password: password.clone(),
            hashes: hashes.join(","),
        });
    }

    let at = rest.find('@').ok_or_else(|| anyhow!("неверный формат"))?;
    let (userinfo, hostport) = rest.split_at(at);
    let hostport = &hostport[1..];
    let colon = userinfo.find(':').ok_or_else(|| anyhow!("нет пароля"))?;
    let password = &userinfo[colon + 1..];
    let peer = if hostport.contains(':') {
        hostport.to_string()
    } else {
        format!("{}:46000", hostport)
    };
    Ok(CsqttConfig { peer, password: password.to_string(), hashes: String::new() })
}

fn parse_query(q: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for kv in q.split('&') {
        if kv.is_empty() { continue; }
        let mut it = kv.splitn(2, '=');
        let k = it.next().unwrap_or("").to_string();
        let v = it.next().unwrap_or("").to_string();
        out.insert(k, v);
    }
    out
}

// ============================================================
//  Скачивание ядра
// ============================================================

fn download_core(dest: &Path) -> Result<()> {
    let url = CORE_URL_TEMPLATE
        .replace("{VER}", CORE_VERSION)
        .replace("{FILE}", CORE_FILENAME);
    log::info!("URL: {}", url);

    let bytes = match ureq::get(&url).call() {
        Ok(resp) => {
            let mut buf = Vec::new();
            resp.into_reader().read_to_end(&mut buf)?;
            buf
        }
        Err(e) => {
            log::warn!("Прямая загрузка: {}. Пробую прокси...", e);
            let proxy = format!("{}{}", PROXY_URL, urlencoding(&url));
            let mut buf = Vec::new();
            ureq::get(&proxy).call()?.into_reader().read_to_end(&mut buf)?;
            buf
        }
    };

    if bytes.len() < 4 || &bytes[..4] != b"\x7fELF" {
        return Err(anyhow!(
            "скачанный файл не ELF (первые байты: {:02x?})",
            &bytes[..4.min(bytes.len())]
        ));
    }

    fs::write(dest, &bytes)?;
    use std::os::unix::fs::PermissionsExt;
    let mut perms = fs::metadata(dest)?.permissions();
    perms.set_mode(0o755);
    fs::set_permissions(dest, perms)?;

    log::info!("Ядро скачано: {} ({} байт)", dest.display(), bytes.len());
    Ok(())
}

fn urlencoding(s: &str) -> String {
    s.replace('%', "%25").replace(':', "%3A").replace('/', "%2F")
        .replace('?', "%3F").replace('&', "%26").replace('=', "%3D")
}

// ============================================================
//  Настройки
// ============================================================

fn load_or_default_settings() -> Settings {
    let path = Path::new(WORK_DIR).join("settings.json");
    if let Ok(data) = fs::read_to_string(&path) {
        if let Ok(s) = serde_json::from_str::<Settings>(&data) {
            return s;
        }
    }
    let s = Settings::default();
    if let Ok(json) = serde_json::to_string_pretty(&s) {
        let _ = fs::write(&path, json);
    }
    s
}

fn total_workers(s: &Settings, hashes: &str) -> u32 {
    let count = hashes.split(',').filter(|h| !h.trim().is_empty()).count().clamp(1, 6) as u32;
    s.workers_per_hash.max(9) * count
}
