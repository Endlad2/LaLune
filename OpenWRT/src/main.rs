use serde_json::{json, Value};
use std::fs;
use std::io::Read;
use std::net::TcpListener;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use tiny_http::{Header, Response, Server, StatusCode};
use uuid::Uuid;

const APP_HTML: &str = include_str!("../../Frontend/app.html");
const OPENWRT_JS: &str = include_str!("../../Frontend/openwrt-api.js");

const LATEST_URL: &str = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST";
const PROXY_URL: &str = "http://31.77.148.203:8855/?url=";

struct AppState {
    is_connected: bool,
    core_process: Option<std::process::Child>,
    configs: Vec<Value>,
    settings: Value,
    logs: Vec<String>,
}

fn parse_host_arg() -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    for i in 0..args.len() {
        if args[i] == "--host" && i + 1 < args.len() {
            return Some(args[i + 1].clone());
        }
    }
    None
}

fn parse_port_arg() -> Option<u16> {
    let args: Vec<String> = std::env::args().collect();
    for i in 0..args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            if let Ok(port) = args[i + 1].parse::<u16>() {
                return Some(port);
            }
        }
    }
    None
}

fn detect_lan_ip() -> Option<String> {
    if let Ok(output) = Command::new("ip")
        .args(["addr", "show", "dev", "br0"])
        .output()
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            for line in stdout.lines() {
                if line.contains("inet ") {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 2 {
                        let ip = parts[1];
                        if let Some(pos) = ip.find('/') {
                            return Some(ip[..pos].to_string());
                        }
                        return Some(ip.to_string());
                    }
                }
            }
        }
    }

    if let Ok(output) = Command::new("ip")
        .args(["addr", "show", "dev", "br-lan"])
        .output()
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            for line in stdout.lines() {
                if line.contains("inet ") {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 2 {
                        let ip = parts[1];
                        if let Some(pos) = ip.find('/') {
                            return Some(ip[..pos].to_string());
                        }
                        return Some(ip.to_string());
                    }
                }
            }
        }
    }

    None
}

fn detect_lan_ip_from_default_route() -> Option<String> {
    if let Ok(output) = Command::new("ip")
        .args(["route", "show", "default"])
        .output()
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            for line in stdout.lines() {
                let parts: Vec<&str> = line.split_whitespace().collect();
                for i in 0..parts.len() {
                    if parts[i] == "dev" && i + 1 < parts.len() {
                        let iface = parts[i + 1];
                        if iface.starts_with("usb")
                            || iface.contains("qmi")
                            || iface.contains("wan")
                            || iface.contains("ppp")
                        {
                            continue;
                        }
                        if let Ok(ip_output) = Command::new("ip")
                            .args(["addr", "show", "dev", iface])
                            .output()
                        {
                            if ip_output.status.success() {
                                let ip_stdout = String::from_utf8_lossy(&ip_output.stdout);
                                for ip_line in ip_stdout.lines() {
                                    if ip_line.contains("inet ") {
                                        let ip_parts: Vec<&str> =
                                            ip_line.split_whitespace().collect();
                                        if ip_parts.len() >= 2 {
                                            let ip = ip_parts[1];
                                            if let Some(pos) = ip.find('/') {
                                                return Some(ip[..pos].to_string());
                                            }
                                            return Some(ip.to_string());
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    None
}

fn get_platform() -> &'static str {
    let uname = Command::new("uname")
        .arg("-m")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    if uname.contains("aarch64") {
        "client-linux-arm64"
    } else if uname.contains("armv7") || uname.contains("armv7l") {
        "client-linux-armv7"
    } else if uname.contains("x86_64") {
        "client-linux-x86_64"
    } else {
        "client-linux-armv7"
    }
}

fn get_data_dir() -> String {
    String::from("/etc/lalune")
}

fn get_configs_path() -> String {
    format!("{}/configs.json", get_data_dir())
}

fn get_settings_path() -> String {
    format!("{}/settings.json", get_data_dir())
}

fn get_latest_path() -> String {
    format!("{}/LATEST", get_data_dir())
}

fn get_core_path() -> String {
    format!("/tmp/{}", get_platform())
}

fn http_get(url: &str) -> Option<String> {
    let url = url.trim();
    println!("[NET] GET: {}", url);

    let output = Command::new("curl")
        .arg("-s")
        .arg("--max-time")
        .arg("8")
        .arg("-A")
        .arg("Mozilla/5.0")
        .arg(url)
        .output();

    match output {
        Ok(o) => {
            if o.status.success() {
                let body = String::from_utf8_lossy(&o.stdout).to_string();
                let trimmed = body.trim().to_string();

                if !trimmed.is_empty()
                    && !trimmed.contains("No connection adapters")
                    && !trimmed.contains("Server error")
                {
                    println!("[NET] OK: {} bytes", trimmed.len());
                    return Some(trimmed);
                }

                println!("[NET] Прокси вернул ошибку: {}", trimmed);
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr);
                println!("[NET] curl error: {}", stderr.trim());
            }
        }
        Err(e) => {
            println!("[NET] curl не найден: {}", e);
        }
    }

    None
}

fn download_file(url: &str, destination: &str) -> bool {
    let url = url.trim();
    let mut urls = vec![url.to_string()];

    if !url.starts_with(PROXY_URL) {
        urls.push(format!("{}?url={}", PROXY_URL.trim(), url));
    }

    for attempt_url in urls {
        let attempt_url = attempt_url.trim();
        println!("[DOWNLOAD] Trying: {}", attempt_url);

        let output = Command::new("curl")
            .arg("-L")
            .arg("-s")
            .arg("--max-time")
            .arg("30")
            .arg("-A")
            .arg("Mozilla/5.0")
            .arg("-o")
            .arg(destination)
            .arg(attempt_url)
            .output();

        let success = match output {
            Ok(o) => o.status.success(),
            Err(e) => {
                println!("[DOWNLOAD] curl не найден: {}", e);
                false
            }
        };

        if !success {
            let _ = fs::remove_file(destination);
            continue;
        }

        let size = fs::metadata(destination).map(|m| m.len()).unwrap_or(0);

        if size < 1024 {
            println!("[DOWNLOAD] Файл слишком маленький ({} байт)", size);
            let _ = fs::remove_file(destination);
            continue;
        }

        println!("[DOWNLOAD] Success: {} ({} bytes)", destination, size);
        return true;
    }

    println!("[DOWNLOAD] Все попытки не удались");
    false
}

fn fetch_latest_version() -> Option<String> {
    println!("[UPDATE] Проверяю LATEST...");

    let direct = http_get(LATEST_URL);
    if let Some(data) = direct {
        let version = data.trim().to_string();
        if !version.is_empty() {
            println!("[UPDATE] Версия: '{}' ({} chars)", version, version.len());
            return Some(version);
        }
        println!("[UPDATE] LATEST пустой");
    } else {
        println!("[UPDATE] Прямой запрос не удался, пробую прокси...");
        let proxied = format!("{}?url={}", PROXY_URL.trim(), LATEST_URL);
        if let Some(data) = http_get(&proxied) {
            let version = data.trim().to_string();
            if !version.is_empty() {
                println!(
                    "[UPDATE] Версия (через прокси): '{}' ({} chars)",
                    version,
                    version.len()
                );
                return Some(version);
            }
        }
    }

    None
}

fn get_local_version() -> String {
    fs::read_to_string(get_latest_path())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn save_latest_version(version: &str) {
    let _ = fs::create_dir_all(get_data_dir());
    let _ = fs::write(get_latest_path(), version.trim());
}

fn update_core(state: &Arc<Mutex<AppState>>) -> bool {
    add_log(state, "[UPDATE] Проверяю LATEST...");

    let version = match fetch_latest_version() {
        Some(v) => {
            let v = v.trim().to_string();
            add_log(state, &format!("[UPDATE] Версия: {}", v));
            v
        }
        None => {
            add_log(state, "[UPDATE] Ошибка: не удалось получить LATEST");
            return false;
        }
    };

    let local = get_local_version();
    if version == local && Path::new(&get_core_path()).exists() {
        add_log(state, "[UPDATE] Ядро уже актуально");
        return true;
    }

    add_log(state, &format!("[UPDATE] Скачиваю ядро v{}...", version));

    let url = format!(
        "https://github.com/Endlad2/csqtt-core/releases/download/{}/{}",
        version.trim(),
        get_platform()
    );

    add_log(state, &format!("[UPDATE] URL: {}", url));

    if download_file(&url, &get_core_path()) {
        let _ = Command::new("chmod")
            .arg("+x")
            .arg(get_core_path())
            .status();
        save_latest_version(&version);
        add_log(state, &format!("[UPDATE] Ядро v{} готово", version));
        true
    } else {
        add_log(state, &format!("[UPDATE] Ошибка скачивания ядра v{}", version));
        add_log(state, &format!("[UPDATE] URL: {}", url));
        false
    }
}

fn load_configs(state: &Arc<Mutex<AppState>>) {
    let configs_path = get_configs_path();
    let _ = fs::create_dir_all(get_data_dir());

    if Path::new(&configs_path).exists() {
        if let Ok(content) = fs::read_to_string(&configs_path) {
            if let Ok(parsed) = serde_json::from_str::<Vec<Value>>(&content) {
                let mut s = state.lock().unwrap();
                s.configs = parsed;
                return;
            }
        }
    }

    let configs: Vec<Value> = vec![];
    let _ = fs::write(&configs_path, "[]");

    let mut s = state.lock().unwrap();
    s.configs = configs;
}

fn save_configs(state: &Arc<Mutex<AppState>>) {
    let s = state.lock().unwrap();
    let configs_path = get_configs_path();
    let _ = fs::write(
        &configs_path,
        serde_json::to_string_pretty(&s.configs).unwrap(),
    );
}

fn ensure_settings(state: &Arc<Mutex<AppState>>) {
    let settings_path = get_settings_path();

    if Path::new(&settings_path).exists() {
        if let Ok(content) = fs::read_to_string(&settings_path) {
            if let Ok(parsed) = serde_json::from_str::<Value>(&content) {
                let mut s = state.lock().unwrap();
                s.settings = parsed;
                return;
            }
        }
    }

    let device_id = Uuid::new_v4().simple().to_string();
    let settings = json!({
        "peer": "",
        "vkHashes": "",
        "turnHost": "",
        "turnPort": "",
        "workersPerHash": 9,
        "obfs": "video",
        "fingerprint": "firefox",
        "clientIds": "8202606,6287487",
        "vkAuthMode": "vkcalls",
        "captchaMode": "auto",
        "deviceId": device_id,
        "autoConnect": false
    });

    let _ = fs::create_dir_all(get_data_dir());
    let _ = fs::write(&settings_path, serde_json::to_string_pretty(&settings).unwrap());

    let mut s = state.lock().unwrap();
    s.settings = settings;
}

fn add_log(state: &Arc<Mutex<AppState>>, message: &str) {
    let mut s = state.lock().unwrap();
    s.logs.push(message.to_string());
    if s.logs.len() > 500 {
        s.logs.remove(0);
    }
}

fn parse_csqtt_link(link: &str) -> Value {
    let mut result = json!({
        "protocol": "CSQTT",
        "peer": "",
        "password": "",
        "hashes": "",
        "name": ""
    });

    if !link.to_lowercase().starts_with("csqtt://") {
        result["peer"] = json!(link);
        result["name"] = json!("Config");
        return result;
    }

    let url_part = link.trim_start_matches("csqtt://");
    let parts: Vec<&str> = url_part.splitn(2, '?').collect();
    let host = parts[0];

    if host == "connect" && parts.len() == 2 {
        let query = parts[1];
        let params: std::collections::HashMap<String, String> = query
            .split('&')
            .filter_map(|p| {
                let kv: Vec<&str> = p.splitn(2, '=').collect();
                if kv.len() == 2 {
                    Some((kv[0].to_string(), kv[1].to_string()))
                } else {
                    None
                }
            })
            .collect();

        let peer_host = params.get("host").cloned().unwrap_or_default();
        let peer_port = params.get("peer").cloned().unwrap_or_default();
        let password = params.get("password").cloned().unwrap_or_default();

        if !peer_host.is_empty() && !peer_port.is_empty() && !password.is_empty() {
            result["peer"] = json!(format!("{}:{}", peer_host, peer_port));
            result["password"] = json!(password);

            if let Some(hashes) = params.get("hashes") {
                let clean: Vec<String> = hashes
                    .split('+')
                    .map(|h| h.to_string())
                    .filter(|h| !h.is_empty())
                    .collect();
                result["hashes"] = json!(clean.join(","));
            }

            result["name"] = json!(format!("{}:{}", peer_host, peer_port));
        }
    } else {
        let userinfo_host: Vec<&str> = url_part.split('@').collect();
        if userinfo_host.len() == 2 {
            result["password"] = json!(userinfo_host[0]);
            result["peer"] = json!(userinfo_host[1]);
            result["name"] = json!(userinfo_host[1]);
        }
    }

    result
}

fn get_free_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.local_addr().unwrap().port()
}

fn build_command(config: &Value, state: &Arc<Mutex<AppState>>) -> Vec<String> {
    let s = state.lock().unwrap();

    let hashes = config["hashes"].as_str().unwrap_or("");
    let hashes_count = hashes
        .split(',')
        .filter(|h| !h.trim().is_empty())
        .count()
        .min(6)
        .max(1);

    let workers_per_hash = s.settings["workersPerHash"]
        .as_i64()
        .unwrap_or(9)
        .max(9) as usize;

    let total_workers = workers_per_hash * hashes_count;

    let listen_port = get_free_port();

    let mut cmd = vec![
        get_core_path(),
        "-peer".to_string(),
        config["peer"].as_str().unwrap_or("").to_string(),
        "-n".to_string(),
        total_workers.to_string(),
        "-listen".to_string(),
        format!("127.0.0.1:{}", listen_port),
        "-vk".to_string(),
        config["hashes"].as_str().unwrap_or("").to_string(),
        "-fingerprint".to_string(),
        s.settings["fingerprint"]
            .as_str()
            .unwrap_or("firefox")
            .to_string(),
        "-client-ids".to_string(),
        s.settings["clientIds"]
            .as_str()
            .unwrap_or("8202606,6287487")
            .to_string(),
        "-obfs".to_string(),
        s.settings["obfs"].as_str().unwrap_or("video").to_string(),
        "-vk-auth-mode".to_string(),
        s.settings["vkAuthMode"]
            .as_str()
            .unwrap_or("vkcalls")
            .to_string(),
        "-device-id".to_string(),
        s.settings["deviceId"].as_str().unwrap_or("").to_string(),
        "-password".to_string(),
        config["password"].as_str().unwrap_or("").to_string(),
        "-captcha-mode".to_string(),
        s.settings["captchaMode"]
            .as_str()
            .unwrap_or("auto")
            .to_string(),
    ];

    let turn_host = s.settings["turnHost"].as_str().unwrap_or("");
    if !turn_host.is_empty() {
        cmd.push("-turn".to_string());
        cmd.push(turn_host.to_string());
    }

    let turn_port = s.settings["turnPort"].as_str().unwrap_or("");
    if !turn_port.is_empty() {
        cmd.push("-port".to_string());
        cmd.push(turn_port.to_string());
    }

    cmd
}

fn start_core(state: &Arc<Mutex<AppState>>, config_id: i64) -> bool {
    let config = {
        let s = state.lock().unwrap();
        s.configs
            .iter()
            .find(|c| c["id"].as_i64() == Some(config_id))
            .cloned()
    };

    let config = match config {
        Some(c) => c,
        None => {
            add_log(state, "[ERROR] Config not found");
            return false;
        }
    };

    if !update_core(state) {
        return false;
    }

    let cmd = build_command(&config, state);
    add_log(state, &format!("[CONNECT] Command: {}", cmd.join(" ")));

    let child = Command::new(&cmd[0])
        .args(&cmd[1..])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();

    let mut child = match child {
        Ok(c) => c,
        Err(e) => {
            add_log(state, &format!("[ERROR] Failed to start core: {}", e));
            return false;
        }
    };

    let stdout = child.stdout.take();
    let state_clone = Arc::clone(state);

    std::thread::spawn(move || {
        if let Some(stdout) = stdout {
            let reader = std::io::BufReader::new(stdout);
            use std::io::BufRead;
            for line in reader.lines() {
                if let Ok(line) = line {
                    let line = line.trim().to_string();
                    if !line.is_empty() {
                        add_log(&state_clone, &line);
                    }
                }
            }
        }
    });

    let mut s = state.lock().unwrap();
    s.is_connected = true;
    s.core_process = Some(child);

    add_log(state, &format!("[CONNECT] Connected to {}", config["name"]));
    true
}

fn stop_core(state: &Arc<Mutex<AppState>>) {
    let mut s = state.lock().unwrap();

    if let Some(ref mut child) = s.core_process {
        let _ = child.kill();
        let _ = child.wait();
    }

    s.core_process = None;
    s.is_connected = false;

    add_log(state, "[DISCONNECT] Stopped");
}

fn handle_request(state: &Arc<Mutex<AppState>>, mut request: tiny_http::Request) {
    let url = request.url().to_string();
    let method = request.method().clone();

    match (method.as_str(), url.as_str()) {
        ("GET", "/") | ("GET", "/app") => {
            let html = APP_HTML.replace("{API_SCRIPT}", "/static/openwrt-api.js");
            let html = html.replace("{QTWEBCHANNEL_SCRIPT}", "");
            let response = Response::from_string(html).with_header(
                Header::from_bytes("Content-Type", "text/html; charset=utf-8").unwrap(),
            );
            let _ = request.respond(response);
        }
        ("GET", "/static/openwrt-api.js") => {
            let response = Response::from_string(OPENWRT_JS).with_header(
                Header::from_bytes("Content-Type", "application/javascript").unwrap(),
            );
            let _ = request.respond(response);
        }
        ("GET", "/api/configs") => {
            let s = state.lock().unwrap();
            let response = Response::from_string(
                serde_json::to_string(&json!({
                    "success": true,
                    "configs": s.configs
                }))
                .unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        ("POST", "/api/configs") => {
            let mut body = String::new();
            let _ = request.as_reader().read_to_string(&mut body);

            let parsed: Value = serde_json::from_str(&body).unwrap_or(json!({}));
            let link = parsed["link"].as_str().unwrap_or("").to_string();

            let mut config = parse_csqtt_link(&link);

            {
                let s = state.lock().unwrap();
                let next_id = s.configs.len() as i64 + 1;
                config["id"] = json!(next_id);
            }

            {
                let mut s = state.lock().unwrap();
                s.configs.push(config);
            }

            save_configs(state);

            let response = Response::from_string(
                serde_json::to_string(&json!({"success": true})).unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        ("DELETE", url_path) if url_path.starts_with("/api/configs/") => {
            let id_str = url_path.trim_start_matches("/api/configs/");
            if let Ok(id) = id_str.parse::<i64>() {
                let mut s = state.lock().unwrap();
                s.configs.retain(|c| c["id"].as_i64() != Some(id));
                save_configs(state);
            }

            let response = Response::from_string(
                serde_json::to_string(&json!({"success": true})).unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        ("GET", "/api/settings") => {
            let s = state.lock().unwrap();
            let response = Response::from_string(
                serde_json::to_string(&json!({
                    "success": true,
                    "settings": s.settings
                }))
                .unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        ("POST", "/api/settings") => {
            let mut body = String::new();
            let _ = request.as_reader().read_to_string(&mut body);

            let parsed: Value = serde_json::from_str(&body).unwrap_or(json!({}));
            let mut settings = parsed["settings"].clone();

            if settings["deviceId"].as_str().unwrap_or("").is_empty() {
                settings["deviceId"] = json!(Uuid::new_v4().simple().to_string());
            }

            let _ = fs::write(
                get_settings_path(),
                serde_json::to_string_pretty(&settings).unwrap(),
            );

            let mut s = state.lock().unwrap();
            s.settings = settings;

            let response = Response::from_string(
                serde_json::to_string(&json!({"success": true})).unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        ("POST", "/api/connect") => {
            let mut body = String::new();
            let _ = request.as_reader().read_to_string(&mut body);

            let parsed: Value = serde_json::from_str(&body).unwrap_or(json!({}));
            let config_id = parsed["config_id"].as_i64().unwrap_or(0);

            let success = start_core(state, config_id);

            let response = Response::from_string(
                serde_json::to_string(&json!({
                    "success": success,
                    "message": if success { "Connected" } else { "Failed" }
                }))
                .unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        ("POST", "/api/disconnect") => {
            stop_core(state);

            let response = Response::from_string(
                serde_json::to_string(&json!({"success": true})).unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        ("GET", "/api/status") => {
            let s = state.lock().unwrap();
            let response = Response::from_string(
                serde_json::to_string(&json!({
                    "success": true,
                    "is_connected": s.is_connected
                }))
                .unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        ("GET", "/api/logs") => {
            let s = state.lock().unwrap();
            let response = Response::from_string(
                serde_json::to_string(&json!({
                    "success": true,
                    "logs": s.logs
                }))
                .unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        ("DELETE", "/api/logs") => {
            let mut s = state.lock().unwrap();
            s.logs.clear();

            let response = Response::from_string(
                serde_json::to_string(&json!({"success": true})).unwrap(),
            )
            .with_header(Header::from_bytes("Content-Type", "application/json").unwrap());
            let _ = request.respond(response);
        }
        _ => {
            let response = Response::from_string("Not Found").with_status_code(StatusCode(404));
            let _ = request.respond(response);
        }
    }
}

fn main() {
    let state = Arc::new(Mutex::new(AppState {
        is_connected: false,
        core_process: None,
        configs: vec![],
        settings: json!({}),
        logs: vec![],
    }));

    let _ = fs::create_dir_all(get_data_dir());

    ensure_settings(&state);
    load_configs(&state);

    let host = if let Some(h) = parse_host_arg() {
        h
    } else {
        detect_lan_ip()
            .or_else(detect_lan_ip_from_default_route)
            .or_else(|| {
                local_ip_address::local_ip()
                    .ok()
                    .map(|ip| ip.to_string())
            })
            .unwrap_or_else(|| "0.0.0.0".to_string())
    };

    let port = parse_port_arg().unwrap_or(9988);

    let bind_addr = format!("{}:{}", host, port);

    println!("========================================");
    println!(" LaLune OpenWRT");
    println!(" UI: http://{}/", bind_addr);
    println!("========================================");

    let server = match Server::http(&bind_addr) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "[ERROR] Не удалось запустить сервер на {}: {}",
                bind_addr, e
            );
            let fallback = format!("0.0.0.0:{}", port);
            println!("[FALLBACK] Пробую: {}", fallback);
            Server::http(&fallback).unwrap()
        }
    };

    for request in server.incoming_requests() {
        handle_request(&state, request);
    }
}
