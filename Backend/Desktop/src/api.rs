// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// HTTP API. deviceId удалён. /smarttunnel/* реально дёргают Lua.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{
        sse::{Event as SseEvent, KeepAlive, Sse},
        IntoResponse, Json,
    },
    routing::{delete, get, post},
    Router,
};
use futures::stream::Stream;
use serde::Deserialize;
use serde_json::{json, Value};
use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;
use tower_http::cors::{Any, CorsLayer};

use crate::config::{parse_link_for_protocol, ConfigItem};
use crate::core_manager::{self, CoreProcess};
use crate::events::Event;
use crate::protocol::{self, ProtocolKind};
use crate::state::{self, AppState};
use crate::vk;
use crate::vpn;

pub const CORE_PREFIX: &str = "[CORE] ";

pub fn router(state: Arc<AppState>) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    Router::new()
        .route("/ping", get(ping))
        .route("/version", get(version))
        .route("/events", get(sse_events))
        .route("/shutdown", post(shutdown))
        .route("/configs", get(configs_list).post(configs_create))
        .route("/configs/parse", post(configs_parse))
        .route("/configs/selected", get(selected_get).put(selected_set))
        .route("/configs/:id", get(configs_get).put(configs_update).delete(configs_delete))
        .route("/settings", get(settings_get).put(settings_put).patch(settings_patch))
        .route("/settings/reset", post(settings_reset))
        .route("/settings/:key", get(settings_get_key).put(settings_put_key))
        .route("/settings-for/:proto", get(settings_for_proto))
        .route("/device/info", get(device_info))
        .route("/vpn/connect", post(vpn_connect))
        .route("/vpn/disconnect", post(vpn_disconnect))
        .route("/vpn/status", get(vpn_status))
        .route("/vpn/reconnect", post(vpn_reconnect))
        .route("/vpn/stats", get(vpn_stats))
        .route("/vpn/tunconf", get(vpn_tunconf))
        .route("/logs", get(logs_all).delete(logs_clear))
        .route("/logs/tail", get(logs_tail))
        .route("/logs/stream", get(sse_logs))
        .route("/logs/export", get(logs_export))
        .route("/core/protocols", get(core_protocols))
        .route("/core/:proto/version", get(core_version_p))
        .route("/core/:proto/latest", get(core_latest_p))
        .route("/core/:proto/check", get(core_check_p))
        .route("/core/:proto/download", post(core_download_async_p))
        .route("/core/:proto/download/sync", post(core_download_sync_p))
        .route("/core/:proto/path", get(core_path_p))
        .route("/core/:proto", delete(core_delete_p))
        .route("/core/version", get(core_version_alias))
        .route("/core/latest", get(core_latest_alias))
        .route("/core/check", get(core_check_alias))
        .route("/core/download", post(core_download_async_alias))
        .route("/core/download/sync", post(core_download_sync_alias))
        .route("/core/path", get(core_path_alias))
        .route("/core", delete(core_delete_alias))
        .route("/update/check", get(update_check))
        .route("/update/url", get(update_url))
        .route("/vk/token/state", get(vk_state))
        .route("/vk/token/login", post(vk_login))
        .route("/vk/token/submit", post(vk_submit))
        .route("/vk/token/validate", get(vk_validate))
        .route("/vk/token/fetch/cancel", post(vk_cancel))
        .route("/vk/token/raw", get(vk_token_raw))
        .route("/vk/token", delete(vk_delete))
        .route("/vk/calls/start", post(vk_calls_start))
        .route("/vk/calls/stop", post(vk_calls_stop))
        .route("/vk/calls/stop-all", post(vk_calls_stop_all))
        .route("/vk/calls/active", get(vk_calls_active))
        .route("/smarttunnel/status", get(st_status))
        .route("/smarttunnel/start", post(st_start))
        .route("/smarttunnel/stop", post(st_stop))
        .route("/smarttunnel/reload", post(st_reload))
        .route("/smarttunnel/logs", get(st_logs))
        .route("/smarttunnel/args", get(st_args).put(st_args_put))
        .route("/deploy/run", post(deploy_stub))
        .route("/deploy/status", get(deploy_status_stub))
        .route("/deploy/log", get(deploy_log_stub))
        .route("/deploy/cancel", post(deploy_stub))
        .route("/deploy/protocols", get(deploy_protocols_stub))
        .route("/platform/capabilities", get(platform_caps))
        .route("/platform/open-url", post(platform_open_url))
        .route("/platform/notify", post(platform_notify))
        .route("/platform/open-path", post(platform_open_path))
        .route("/platform/share", post(platform_share))
        .route("/debug/state", get(debug_state))
        .route("/debug/echo", post(debug_echo))
        .route("/debug/config", get(debug_config))
        .route("/debug/reload-config", post(debug_reload))
        .route("/debug/lua", get(debug_lua))
        .route("/debug/lua/eval", post(debug_lua_eval))
        .layer(cors)
        .with_state(state)
}

async fn ping(State(state): State<Arc<AppState>>) -> Json<Value> {
    Json(json!({
        "ok": true,
        "version": "0.6.0",
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "hostname": hostname::get().ok().and_then(|s| s.into_string().ok()).unwrap_or_default(),
        "platform": "desktop",
        "uptime": state.uptime(),
    }))
}

async fn version() -> Json<Value> {
    Json(json!({
        "api": 1,
        "backend": "0.6.0",
        "core": "unknown",
        "ui": "0.6.0",
    }))
}

async fn shutdown(State(state): State<Arc<AppState>>) -> Json<Value> {
    state.notify_shutdown();
    Json(json!({"ok": true}))
}

async fn sse_events(
    State(state): State<Arc<AppState>>,
) -> Sse<impl Stream<Item = Result<SseEvent, Infallible>>> {
    let mut rx = state.events.subscribe();
    let stream = async_stream::stream! {
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    let data = serde_json::to_string(&ev).unwrap_or_default();
                    yield Ok(SseEvent::default().data(data));
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    };
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}

async fn sse_logs(
    State(state): State<Arc<AppState>>,
) -> Sse<impl Stream<Item = Result<SseEvent, Infallible>>> {
    let mut rx = state.events.subscribe();
    let stream = async_stream::stream! {
        loop {
            match rx.recv().await {
                Ok(Event::Log { line, .. }) => {
                    let data = serde_json::to_string(&json!({"line": line})).unwrap_or_default();
                    yield Ok(SseEvent::default().data(data));
                }
                Ok(_) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    };
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}

async fn configs_list(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    match state.configs.list() {
        Ok(v) => Json(json!(v)).into_response(),
        Err(e) => err(500, e.to_string()),
    }
}

async fn configs_get(
    State(state): State<Arc<AppState>>,
    Path(id): Path<i64>,
) -> impl IntoResponse {
    match state.configs.get(id) {
        Ok(Some(c)) => Json(json!(c)).into_response(),
        Ok(None) => err(404, "not found"),
        Err(e) => err(500, e.to_string()),
    }
}

#[derive(Deserialize)]
struct ConfigCreateBody {
    protocol: Option<String>,
    link: Option<String>,
    peer: Option<String>,
    password: Option<String>,
    hashes: Option<String>,
    name: Option<String>,
    #[serde(rename = "profileId")] profile_id: Option<String>,
    #[serde(rename = "profileToken")] profile_token: Option<String>,
    #[serde(rename = "clientIp")] client_ip: Option<String>,
    transport: Option<String>,
    url: Option<String>,
    urls: Option<String>,
    #[serde(rename = "volgaUrl")] volga_url: Option<String>,
    #[serde(rename = "relayUrl")] relay_url: Option<String>,
    #[serde(rename = "relayToken")] relay_token: Option<String>,
    #[serde(rename = "maxToken")] max_token: Option<String>,
    #[serde(rename = "maxUid")] max_uid: Option<String>,
    server: Option<String>,
}

fn body_to_item(body: ConfigCreateBody) -> Result<ConfigItem, String> {
    let protocol = body.protocol.unwrap_or_else(|| "CSQTT".into());
    if let Some(link) = body.link.as_ref().filter(|l| !l.trim().is_empty()) {
        return parse_link_for_protocol(link, &protocol).map_err(|e| e.to_string());
    }
    let mut c = ConfigItem::default();
    c.protocol = protocol;
    c.peer = body.peer.unwrap_or_default();
    c.password = body.password.unwrap_or_default();
    c.hashes = body.hashes.unwrap_or_default();
    c.name = body.name.unwrap_or_default();
    c.profile_id = body.profile_id.unwrap_or_default();
    c.profile_token = body.profile_token.unwrap_or_default();
    c.client_ip = body.client_ip.unwrap_or_default();
    c.transport = body.transport.unwrap_or_default();
    c.url = body.url.unwrap_or_default();
    c.urls = body.urls.unwrap_or_default();
    c.volga_url = body.volga_url.unwrap_or_default();
    c.relay_url = body.relay_url.unwrap_or_default();
    c.relay_token = body.relay_token.unwrap_or_default();
    c.max_token = body.max_token.unwrap_or_default();
    c.max_uid = body.max_uid.unwrap_or_default();
    c.server = body.server.unwrap_or_default();
    if c.name.is_empty() {
        c.name = if c.peer.is_empty() { c.server.clone() } else { c.peer.clone() };
    }
    Ok(c)
}

async fn configs_create(
    State(state): State<Arc<AppState>>,
    Json(body): Json<ConfigCreateBody>,
) -> impl IntoResponse {
    let config = match body_to_item(body) {
        Ok(c) => c,
        Err(e) => return err(400, e),
    };
    match state.configs.insert(&config) {
        Ok(id) => Json(json!({"id": id})).into_response(),
        Err(e) => err(500, e.to_string()),
    }
}

async fn configs_update(
    State(state): State<Arc<AppState>>,
    Path(id): Path<i64>,
    Json(body): Json<ConfigCreateBody>,
) -> impl IntoResponse {
    let config = match body_to_item(body) {
        Ok(c) => c,
        Err(e) => return err(400, e),
    };
    match state.configs.update(id, &config) {
        Ok(_) => Json(json!({"ok": true})).into_response(),
        Err(e) => err(500, e.to_string()),
    }
}

async fn configs_delete(
    State(state): State<Arc<AppState>>,
    Path(id): Path<i64>,
) -> impl IntoResponse {
    match state.configs.delete(id) {
        Ok(_) => Json(json!({"ok": true})).into_response(),
        Err(e) => err(500, e.to_string()),
    }
}

#[derive(Deserialize)]
struct ParseBody {
    link: String,
    protocol: Option<String>,
}

async fn configs_parse(Json(body): Json<ParseBody>) -> impl IntoResponse {
    let protocol = body.protocol.unwrap_or_else(|| "CSQTT".into());
    match parse_link_for_protocol(&body.link, &protocol) {
        Ok(c) => Json(json!(c)).into_response(),
        Err(e) => err(400, e.to_string()),
    }
}

async fn selected_get(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let c = state.selected_config.read().clone();
    match c {
        Some(c) => Json(json!(c)).into_response(),
        None => Json(json!({})).into_response(),
    }
}

#[derive(Deserialize)]
struct SelectedSetBody { id: Option<i64> }

async fn selected_set(
    State(state): State<Arc<AppState>>,
    Json(body): Json<SelectedSetBody>,
) -> impl IntoResponse {
    if let Some(id) = body.id {
        match state.configs.get(id) {
            Ok(Some(c)) => {
                *state.selected_config.write() = Some(c);
                Json(json!({"ok": true})).into_response()
            }
            Ok(None) => err(404, "config not found"),
            Err(e) => err(500, e.to_string()),
        }
    } else {
        *state.selected_config.write() = None;
        Json(json!({"ok": true})).into_response()
    }
}

async fn settings_get(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let s = state.settings.read().clone();
    Json(json!(s))
}

async fn settings_for_proto(
    Path(proto): Path<String>,
) -> impl IntoResponse {
    let kind = ProtocolKind::from_id(&proto).unwrap_or(ProtocolKind::Csqtt);
    Json(json!({
        "protocol": kind.id(),
        "keys": protocol::settings_keys_for(kind),
        "linkPlaceholder": protocol::link_placeholder(kind),
    }))
}

async fn settings_put(
    State(state): State<Arc<AppState>>,
    Json(body): Json<Value>,
) -> impl IntoResponse {
    let mut s: crate::settings::Settings = match serde_json::from_value(body) {
        Ok(s) => s,
        Err(e) => return err(400, e.to_string()),
    };
    s.normalize();
    *state.settings.write() = s;
    if let Err(e) = state.save_settings() { return err(500, e.to_string()); }
    Json(json!({"ok": true})).into_response()
}

async fn settings_patch(
    State(state): State<Arc<AppState>>,
    Json(body): Json<Value>,
) -> impl IntoResponse {
    let mut s = state.settings.read().clone();
    if let Err(e) = s.merge_from_json(body) { return err(400, e.to_string()); }
    *state.settings.write() = s;
    if let Err(e) = state.save_settings() { return err(500, e.to_string()); }
    Json(json!({"ok": true})).into_response()
}

async fn settings_reset(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut s = crate::settings::Settings::default();
    s.normalize();
    *state.settings.write() = s;
    let _ = state.save_settings();
    Json(json!({"ok": true}))
}

async fn settings_get_key(
    State(state): State<Arc<AppState>>,
    Path(key): Path<String>,
) -> impl IntoResponse {
    let s = state.settings.read().clone();
    match s.get_field(&key) {
        Some(v) => Json(v).into_response(),
        None => err(404, "key not found"),
    }
}

async fn settings_put_key(
    State(state): State<Arc<AppState>>,
    Path(key): Path<String>,
    Json(body): Json<Value>,
) -> impl IntoResponse {
    let mut s = state.settings.read().clone();
    if let Err(e) = s.set_field(&key, body) { return err(400, e.to_string()); }
    *state.settings.write() = s;
    let _ = state.save_settings();
    Json(json!({"ok": true})).into_response()
}

async fn device_info() -> impl IntoResponse {
    let hostname = hostname::get()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let cores = num_cpus::get();
    Json(json!({
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "hostname": hostname,
        "cores": cores,
        "totalMemMb": 0,
    }))
}

#[derive(Deserialize)]
struct ConnectBody {
    #[serde(rename = "configId")]
    config_id: Option<i64>,
}

async fn vpn_connect(
    State(state): State<Arc<AppState>>,
    Json(body): Json<ConnectBody>,
) -> impl IntoResponse {
    let config = if let Some(id) = body.config_id {
        state.configs.get(id).ok().flatten()
    } else {
        state.selected_config.read().clone()
    };

    let config = match config {
        Some(c) => c,
        None => return err(400, "no config selected"),
    };

    let kind = ProtocolKind::from_id(&config.protocol).unwrap_or(ProtocolKind::Csqtt);
    state.log(format!("[VPN] connecting to {} ({})", config.name, kind.id()));

    let core_path = state::core_path_for(&state.app_dir, &config.protocol);

    if !core_path.exists() {
        state.log(format!("[VPN] {} core not found, downloading...", kind.id()));
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .unwrap();

        match kind {
            ProtocolKind::Csqtt => {
                if config.protocol.trim().eq_ignore_ascii_case("CSQTT 2.1.9") {
                    if let Err(e) = core_manager::download_csqtt_219(&client, &core_path, &state.events).await {
                        return err(500, format!("download CSQTT 2.1.9 failed: {}", e));
                    }
                } else {
                    let version = match core_manager::fetch_latest_csqtt(&client, &state.events).await {
                        Some(v) => v,
                        None => return err(500, "cannot fetch CSQTT LATEST"),
                    };
                    if let Err(e) = core_manager::download_csqtt(&client, &version, &core_path, &state.events).await {
                        return err(500, format!("download CSQTT failed: {}", e));
                    }
                }
            }
            ProtocolKind::PaperFlux => {
                if let Err(e) = core_manager::download_paperflux(&client, &core_path, &state.events).await {
                    return err(500, format!("download PaperFlux failed: {}", e));
                }
            }
        }
    }

    let settings = state.settings.read().clone();
    let args = core_manager::build_args(&config, &settings, vpn::CORE_LISTEN_PORT);
    state.log(format!("[VPN] core args: {}", args.join(" ")));

    let core = match CoreProcess::spawn(&core_path, &args, &state.logs_path, state.events.clone()).await {
        Ok(c) => c,
        Err(e) => return err(500, format!("spawn failed: {}", e)),
    };
    *state.core.lock() = Some(core);

    if kind == ProtocolKind::Csqtt && settings.share_vpn {
        match crate::socks5::start(state.clone()) {
            Ok(port) => state.log(format!("[PROXY] socks5 on port {}", port)),
            Err(e) => state.log(format!("[PROXY] failed to start: {}", e)),
        }
    }

    if let Some(lua) = state.lua() {
        lua.on_connect();
    }

    let state2 = state.clone();
    let kind_for_watchdog = kind;
    tokio::spawn(async move {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
        let mut last_size = 0u64;
        let mut tun_ip: Option<String> = None;
        let mut tun_dns: Option<String> = None;
        let mut consecutive_active_ticks: i32 = 0;
        let mut tun_started = false;

        while tokio::time::Instant::now() < deadline && !tun_started {
            if let Ok(meta) = tokio::fs::metadata(&state2.logs_path).await {
                if meta.len() > last_size {
                    if let Ok(content) = tokio::fs::read_to_string(&state2.logs_path).await {
                        let start = (last_size as usize).min(content.len());
                        let new_part = &content[start..];
                        for line in new_part.lines() {
                            if let Some((ip, dns)) = vpn::parse_tunconf(line) {
                                tun_ip = Some(ip);
                                tun_dns = Some(dns);
                            }
                            if let Some((active, _traffic)) = vpn::parse_stats(line) {
                                if active > 0 { consecutive_active_ticks += 1; }
                                else { consecutive_active_ticks = 0; }
                            }
                        }
                        last_size = meta.len();
                    }
                }
            }

            let ready = match kind_for_watchdog {
                ProtocolKind::Csqtt => {
                    tun_ip.is_some() && tun_dns.is_some() && consecutive_active_ticks >= 2
                }
                ProtocolKind::PaperFlux => {
                    consecutive_active_ticks >= 1
                        || last_size > 0
                }
            };

            if ready {
                let ip = tun_ip.clone()
                    .unwrap_or_else(|| vpn::DEFAULT_TUN_IP.to_string());
                let dns = tun_dns.clone()
                    .unwrap_or_else(|| vpn::DEFAULT_DNS.to_string());

                state2.log(format!(
                    "[VPN] TUN params: ip={} dns={} (proto={})",
                    ip, dns, kind_for_watchdog.id()
                ));

                if let Err(e) = vpn::start_tun(state2.vpn.clone(), ip, dns, state2.events.clone()) {
                    state2.log(format!("[VPN] tun start failed: {}", e));
                    state2.events.emit(Event::error(format!("tun start failed: {}", e)));
                    return;
                }

                state2.events.emit(Event::status(true));
                state2.log("[VPN] connected");
                tun_started = true;
            }

            if !tun_started {
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
        }

        if !tun_started {
            state2.log("[VPN] timeout waiting for TUN/active");
            state2.events.emit(Event::status(false));
        }
    });

    Json(json!({"ok": true, "status": "connecting"})).into_response()
}

async fn vpn_disconnect(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    state.log("[VPN] disconnecting...");
    state.vpn.stop();
    vpn::cleanup_routes(&state.vpn, &state.events);
    crate::socks5::stop(&state);

    let maybe_proc = { let mut core = state.core.lock(); core.take() };
    if let Some(mut p) = maybe_proc { let _ = p.kill().await; }
    state.events.emit(Event::status(false));

    if let Some(lua) = state.lua() {
        lua.on_disconnect();
    }

    Json(json!({"ok": true}))
}

async fn vpn_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let cfg_id = state.selected_config.read().as_ref().map(|c| c.id).unwrap_or(0);
    let s = state.vpn.status(cfg_id);
    let socks5_port = *state.socks5_port.read();
    Json(json!({
        "state": s.state,
        "connected": s.connected,
        "uptimeSec": s.uptime_sec,
        "configId": s.config_id,
        "message": s.message,
        "since": s.since,
        "socks5Port": socks5_port,
    }))
}

async fn vpn_reconnect(state: State<Arc<AppState>>) -> impl IntoResponse {
    let _ = vpn_disconnect(state.clone()).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let _ = vpn_connect(state, Json(ConnectBody { config_id: None })).await;
    Json(json!({"ok": true}))
}

async fn vpn_stats(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let s = state.vpn.stats();
    let socks5_port = *state.socks5_port.read();
    Json(json!({
        "rxBytes": s.rx_bytes,
        "txBytes": s.tx_bytes,
        "rxRate": s.rx_rate,
        "txRate": s.tx_rate,
        "activeSessions": s.active_sessions,
        "socks5Port": socks5_port,
    }))
}

async fn vpn_tunconf(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let c = state.vpn.tun_conf.lock().clone();
    match c { Some(c) => Json(json!(c)).into_response(), None => Json(json!({})).into_response() }
}

fn filter_logs(all: &[String], source: Option<&str>) -> Vec<String> {
    match source {
        Some("core") => all.iter().filter(|l| l.starts_with(CORE_PREFIX)).cloned().collect(),
        Some("backend") => all.iter().filter(|l| !l.starts_with(CORE_PREFIX)).cloned().collect(),
        _ => all.to_vec(),
    }
}

#[derive(Deserialize)]
struct LogsQuery {
    lines: Option<usize>,
    source: Option<String>,
}

async fn logs_all(
    State(state): State<Arc<AppState>>,
    Query(q): Query<LogsQuery>,
) -> impl IntoResponse {
    let logs = state.logs_snapshot();
    let filtered = filter_logs(&logs, q.source.as_deref());
    Json(json!(filtered))
}

async fn logs_tail(
    State(state): State<Arc<AppState>>,
    Query(q): Query<LogsQuery>,
) -> impl IntoResponse {
    let n = q.lines.unwrap_or(100);
    let logs = state.logs_snapshot();
    let filtered = filter_logs(&logs, q.source.as_deref());
    let start = filtered.len().saturating_sub(n);
    Json(json!(filtered[start..].to_vec()))
}

async fn logs_clear(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    state.logs.lock().clear();
    Json(json!({"ok": true}))
}

async fn logs_export(
    State(state): State<Arc<AppState>>,
    Query(q): Query<LogsQuery>,
) -> impl IntoResponse {
    let logs = state.logs_snapshot();
    let filtered = filter_logs(&logs, q.source.as_deref());
    let body = filtered.join("\n");
    (StatusCode::OK, [("content-type", "text/plain; charset=utf-8")], body)
}

async fn core_protocols() -> impl IntoResponse {
    Json(json!(core_manager::supported_protocols()))
}

async fn core_version_p(
    State(state): State<Arc<AppState>>,
    Path(proto): Path<String>,
) -> impl IntoResponse {
    let kind = ProtocolKind::from_id(&proto).unwrap_or(ProtocolKind::Csqtt);
    let latest_file = state.app_dir.join(if proto.trim().eq_ignore_ascii_case("CSQTT 2.1.9") { "LATEST.CSQTT-2.1.9" } else { if kind == ProtocolKind::Csqtt { "LATEST.Csqtt" } else { "LATEST.PaperFlux" } });
    let version = tokio::fs::read_to_string(&latest_file)
        .await
        .unwrap_or_default()
        .trim()
        .to_string();
    Json(json!({"version": version}))
}

async fn core_latest_p(
    State(state): State<Arc<AppState>>,
    Path(proto): Path<String>,
) -> impl IntoResponse {
    let kind = ProtocolKind::from_id(&proto).unwrap_or(ProtocolKind::Csqtt);
    let client = reqwest::Client::builder().timeout(Duration::from_secs(30)).build().unwrap();
    let v = if proto.trim().eq_ignore_ascii_case("CSQTT 2.1.9") {
        Some(core_manager::CSQTT_219_RELEASE.to_string())
    } else {
        match kind {
            ProtocolKind::Csqtt => core_manager::fetch_latest_csqtt(&client, &state.events).await,
            ProtocolKind::PaperFlux => core_manager::fetch_latest_paperflux(&client, &state.events).await,
        }
    };
    match v {
        Some(v) => Json(json!({"version": v})).into_response(),
        None => err(500, "cannot fetch LATEST"),
    }
}

async fn core_check_p(
    State(state): State<Arc<AppState>>,
    Path(proto): Path<String>,
) -> impl IntoResponse {
    let kind = ProtocolKind::from_id(&proto).unwrap_or(ProtocolKind::Csqtt);
    let client = reqwest::Client::builder().timeout(Duration::from_secs(30)).build().unwrap();
    let remote = if proto.trim().eq_ignore_ascii_case("CSQTT 2.1.9") {
        core_manager::CSQTT_219_RELEASE.to_string()
    } else {
        match kind {
            ProtocolKind::Csqtt => core_manager::fetch_latest_csqtt(&client, &state.events).await.unwrap_or_default(),
            ProtocolKind::PaperFlux => core_manager::fetch_latest_paperflux(&client, &state.events).await.unwrap_or_default(),
        }
    };
    let latest_file = state.app_dir.join(if proto.trim().eq_ignore_ascii_case("CSQTT 2.1.9") { "LATEST.CSQTT-2.1.9" } else { if kind == ProtocolKind::Csqtt { "LATEST.Csqtt" } else { "LATEST.PaperFlux" } });
    let local = tokio::fs::read_to_string(&latest_file)
        .await
        .unwrap_or_default()
        .trim()
        .to_string();
    let has_update = !remote.is_empty() && remote != local;
    Json(json!({"hasUpdate": has_update, "local": local, "remote": remote}))
}

async fn core_download_async_p(
    State(state): State<Arc<AppState>>,
    Path(proto): Path<String>,
) -> impl IntoResponse {
    if *state.core_downloading.lock() { return err(409, "already downloading"); }
    *state.core_downloading.lock() = true;

    let use_csqtt_219 = proto.trim().eq_ignore_ascii_case("CSQTT 2.1.9");
    let kind = ProtocolKind::from_id(&proto).unwrap_or(ProtocolKind::Csqtt);
    let state2 = state.clone();
    tokio::spawn(async move {
        state2.events.emit(Event::progress("core_download", 0));
        let client = reqwest::Client::builder().timeout(Duration::from_secs(60)).build().unwrap();
        let dest = crate::state::core_path_for(&state2.app_dir, &proto);
        let latest_file = state2.app_dir.join(if use_csqtt_219 { "LATEST.CSQTT-2.1.9" } else if kind == ProtocolKind::Csqtt { "LATEST.Csqtt" } else { "LATEST.PaperFlux" });

        match kind {
            ProtocolKind::Csqtt => {
                let version = if use_csqtt_219 {
                    Some(core_manager::CSQTT_219_RELEASE.to_string())
                } else {
                    core_manager::fetch_latest_csqtt(&client, &state2.events).await
                };
                if let Some(version) = version {
                    state2.events.emit(Event::progress("core_download", 20));
                    let download = if use_csqtt_219 {
                        core_manager::download_csqtt_219(&client, &dest, &state2.events).await
                    } else {
                        core_manager::download_csqtt(&client, &version, &dest, &state2.events).await
                    };
                    match download {
                        Ok(_) => {
                            let saved_version = version;
                            let _ = tokio::fs::write(&latest_file, &saved_version).await;
                            state2.events.emit(Event::progress("core_download", 100));
                            state2.log(format!("[CORE] CSQTT updated to {}", saved_version));
                        }
                        Err(e) => {
                            state2.log(format!("[CORE] CSQTT download failed: {}", e));
                            state2.events.emit(Event::error(e.to_string()));
                        }
                    }
                }
            }
            ProtocolKind::PaperFlux => {
                state2.events.emit(Event::progress("core_download", 20));
                match core_manager::download_paperflux(&client, &dest, &state2.events).await {
                    Ok(_) => {
                        let _ = tokio::fs::write(&latest_file, "latest").await;
                        state2.events.emit(Event::progress("core_download", 100));
                        state2.log("[CORE] PaperFlux updated".to_string());
                    }
                    Err(e) => {
                        state2.log(format!("[CORE] PaperFlux download failed: {}", e));
                        state2.events.emit(Event::error(e.to_string()));
                    }
                }
            }
        }
        *state2.core_downloading.lock() = false;
    });

    Json(json!({"ok": true, "async": true})).into_response()
}

async fn core_download_sync_p(
    State(state): State<Arc<AppState>>,
    Path(proto): Path<String>,
) -> impl IntoResponse {
    if *state.core_downloading.lock() { return err(409, "already downloading"); }
    *state.core_downloading.lock() = true;

    let use_csqtt_219 = proto.trim().eq_ignore_ascii_case("CSQTT 2.1.9");
    let kind = ProtocolKind::from_id(&proto).unwrap_or(ProtocolKind::Csqtt);
    let client = reqwest::Client::builder().timeout(Duration::from_secs(60)).build().unwrap();
    let dest = crate::state::core_path_for(&state.app_dir, &proto);
    let latest_file = state.app_dir.join(if proto.trim().eq_ignore_ascii_case("CSQTT 2.1.9") { "LATEST.CSQTT-2.1.9" } else { if kind == ProtocolKind::Csqtt { "LATEST.Csqtt" } else { "LATEST.PaperFlux" } });

    let result = match kind {
        ProtocolKind::Csqtt => {
            let version = if use_csqtt_219 {
                core_manager::CSQTT_219_RELEASE.to_string()
            } else {
                match core_manager::fetch_latest_csqtt(&client, &state.events).await {
                    Some(v) => v,
                    None => { *state.core_downloading.lock() = false; return err(500, "cannot fetch LATEST"); }
                }
            };
            let download = if use_csqtt_219 {
                core_manager::download_csqtt_219(&client, &dest, &state.events).await
            } else {
                core_manager::download_csqtt(&client, &version, &dest, &state.events).await
            };
            match download {
                Ok(_) => {
                    let saved_version = version;
                    let _ = tokio::fs::write(&latest_file, &saved_version).await;
                    Ok(saved_version)
                }
                Err(e) => Err(e),
            }
        }
        ProtocolKind::PaperFlux => {
            match core_manager::download_paperflux(&client, &dest, &state.events).await {
                Ok(_) => {
                    let _ = tokio::fs::write(&latest_file, "latest").await;
                    Ok("latest".to_string())
                }
                Err(e) => Err(e),
            }
        }
    };

    *state.core_downloading.lock() = false;
    match result {
        Ok(v) => Json(json!({"ok": true, "version": v})).into_response(),
        Err(e) => err(500, e.to_string()),
    }
}

async fn core_path_p(
    State(state): State<Arc<AppState>>,
    Path(proto): Path<String>,
) -> impl IntoResponse {
    let kind = ProtocolKind::from_id(&proto).unwrap_or(ProtocolKind::Csqtt);
    let p = crate::state::core_path_for(&state.app_dir, &proto);
    Json(json!({"path": p.to_string_lossy()}))
}

async fn core_delete_p(
    State(state): State<Arc<AppState>>,
    Path(proto): Path<String>,
) -> impl IntoResponse {
    let kind = ProtocolKind::from_id(&proto).unwrap_or(ProtocolKind::Csqtt);
    let p = crate::state::core_path_for(&state.app_dir, &proto);
    let _ = tokio::fs::remove_file(&p).await;
    Json(json!({"ok": true}))
}

async fn core_version_alias(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let latest_file = state.app_dir.join("LATEST.Csqtt");
    let version = tokio::fs::read_to_string(&latest_file).await.unwrap_or_default().trim().to_string();
    Json(json!({"version": version}))
}

async fn core_latest_alias(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let client = reqwest::Client::builder().timeout(Duration::from_secs(30)).build().unwrap();
    match core_manager::fetch_latest_csqtt(&client, &state.events).await {
        Some(v) => Json(json!({"version": v})).into_response(),
        None => err(500, "cannot fetch LATEST"),
    }
}

async fn core_check_alias(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let client = reqwest::Client::builder().timeout(Duration::from_secs(30)).build().unwrap();
    let remote = core_manager::fetch_latest_csqtt(&client, &state.events).await.unwrap_or_default();
    let local = tokio::fs::read_to_string(state.app_dir.join("LATEST.Csqtt"))
        .await.unwrap_or_default().trim().to_string();
    let has_update = !remote.is_empty() && remote != local;
    Json(json!({"hasUpdate": has_update, "local": local, "remote": remote}))
}

async fn core_download_async_alias(state: State<Arc<AppState>>) -> impl IntoResponse {
    core_download_async_p(state, Path("CSQTT".into())).await
}

async fn core_download_sync_alias(state: State<Arc<AppState>>) -> impl IntoResponse {
    core_download_sync_p(state, Path("CSQTT".into())).await
}

async fn core_path_alias(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let p = crate::state::core_path_for(&state.app_dir, "CSQTT");
    Json(json!({"path": p.to_string_lossy()}))
}

async fn core_delete_alias(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let p = crate::state::core_path_for(&state.app_dir, "CSQTT");
    let _ = tokio::fs::remove_file(&p).await;
    Json(json!({"ok": true}))
}

async fn update_check(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let client = reqwest::Client::builder().timeout(Duration::from_secs(15)).build().unwrap();
    let url = "https://api.github.com/repos/Endlad2/LaLune/releases/latest";
    let resp = client.get(url)
        .header("User-Agent", core_manager::USER_AGENT_BROWSER)
        .header("Accept", "application/vnd.github+json")
        .send().await;
    let remote_tag = match resp {
        Ok(r) => r.json::<Value>().await.ok()
            .and_then(|v| v.get("tag_name").and_then(|x| x.as_str()).map(String::from))
            .unwrap_or_default(),
        Err(_) => String::new(),
    };
    let local = "0.6.0";
    let has_update = !remote_tag.is_empty() && remote_tag != local;
    let _ = &state;
    Json(json!({"hasUpdate": has_update, "remoteTag": remote_tag, "localVersion": local}))
}

async fn update_url() -> impl IntoResponse {
    Json(json!({"url": "https://github.com/Endlad2/LaLune/releases/latest"}))
}

async fn vk_state(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(json!(vk::token_state(&state.app_dir)))
}

async fn vk_login(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    {
        match vk::launch_token_fetcher(state.events.clone()).await {
            Ok(_) => Json(json!({"ok": true, "needsUi": false})).into_response(),
            Err(e) => err(500, e.to_string()),
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        Json(json!({"ok": true, "needsUi": true, "authUrl": vk::auth_url()})).into_response()
    }
}

#[derive(Deserialize)]
struct VkSubmitBody { token: String }

async fn vk_submit(
    State(state): State<Arc<AppState>>,
    Json(body): Json<VkSubmitBody>,
) -> impl IntoResponse {
    match vk::save_token(&state.app_dir, &body.token) {
        Ok(_) => { state.log("[VK] token saved via /vk/token/submit"); Json(json!({"ok": true})).into_response() }
        Err(e) => err(500, e.to_string()),
    }
}

async fn vk_validate(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    match vk::read_token(&state.app_dir) {
        Some(t) => match vk::validate_token(&t).await {
            Ok(true) => Json(json!({"valid": true, "message": ""})).into_response(),
            Ok(false) => Json(json!({"valid": false, "message": "invalid token"})).into_response(),
            Err(e) => Json(json!({"valid": false, "message": e.to_string()})).into_response(),
        },
        None => Json(json!({"valid": false, "message": "no token"})).into_response(),
    }
}

async fn vk_token_raw(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let token = vk::read_token(&state.app_dir).unwrap_or_default();
    Json(json!({"token": token}))
}

async fn vk_cancel() -> impl IntoResponse { Json(json!({"ok": true})) }

async fn vk_delete(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let _ = vk::delete_token(&state.app_dir);
    state.log("[VK] token deleted");
    Json(json!({"ok": true}))
}

#[derive(Deserialize)]
struct VkCallsStartBody {
    workers: Option<i32>,
    #[serde(rename = "autoApiWorkers")] auto_api_workers: Option<i32>,
}

async fn vk_calls_start(
    State(state): State<Arc<AppState>>,
    Json(body): Json<VkCallsStartBody>,
) -> impl IntoResponse {
    let token = match vk::read_token(&state.app_dir) { Some(t) => t, None => return err(400, "no VK token") };
    let settings = state.settings.read().clone();
    let workers = body.workers.unwrap_or(settings.workers);
    let auto_api_workers = body.auto_api_workers.unwrap_or(settings.auto_api_workers);
    let count = vk::call_count_for_workers(workers, auto_api_workers);
    let client = vk::VkApiClient::new(token);
    let mut hashes = Vec::new();
    let mut call_ids = Vec::new();

    for slot in 0..count {
        if slot > 0 {
            let delay = if count <= 4 { 80 } else { 202 };
            tokio::time::sleep(Duration::from_millis(delay)).await;
        }
        let result = client.start_call().await;
        if result.is_success() {
            hashes.push(result.hash.clone()); call_ids.push(result.call_id.clone());
        } else if result.token_invalid() {
            return err(401, "VK token invalid");
        }
    }

    if hashes.is_empty() { return err(500, "no calls created"); }
    Json(json!({"hashes": hashes, "callIds": call_ids})).into_response()
}

#[derive(Deserialize)]
struct VkCallsStopBody { #[serde(rename = "callIds")] call_ids: Vec<String> }

async fn vk_calls_stop(
    State(state): State<Arc<AppState>>,
    Json(body): Json<VkCallsStopBody>,
) -> impl IntoResponse {
    let token = match vk::read_token(&state.app_dir) { Some(t) => t, None => return err(400, "no VK token") };
    let client = vk::VkApiClient::new(token);
    let mut finished = 0;
    for id in body.call_ids { if client.force_finish(&id).await { finished += 1; } }
    Json(json!({"finished": finished})).into_response()
}

async fn vk_calls_stop_all(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let _ = state; Json(json!({"finished": 0}))
}

async fn vk_calls_active() -> impl IntoResponse { Json(json!({"callIds": []})) }

// ============================================================
//  SmartTunnel — реальные вызовы Lua
// ============================================================

async fn st_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let running = *state.smarttunnel_running.lock();
    let lua_available = state.lua().is_some();
    Json(json!({
        "running": running,
        "luaAvailable": lua_available,
    }))
}

async fn st_start(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    *state.smarttunnel_running.lock() = true;
    state.log("[SMART-TUNNEL] start");
    if let Some(lua) = state.lua() {
        lua.on_connect();
    }
    Json(json!({"ok": true}))
}

async fn st_stop(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    *state.smarttunnel_running.lock() = false;
    state.log("[SMART-TUNNEL] stop");
    if let Some(lua) = state.lua() {
        lua.on_disconnect();
    }
    Json(json!({"ok": true}))
}

async fn st_reload(State(state): State<Arc<AppState>>) -> axum::response::Response {
    state.log("[SMART-TUNNEL] reload");
    match state.init_lua() {
        Ok(_) => Json(json!({"ok": true})).into_response(),
        Err(e) => err(500, format!("lua reload failed: {e:#}")),
    }
}

async fn st_logs(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let logs = state.logs_snapshot();
    let filtered: Vec<String> = logs
        .into_iter()
        .filter(|l| l.starts_with("[SMART-TUNNEL]") || l.starts_with("[LUA]"))
        .collect();
    Json(json!(filtered))
}

async fn st_args() -> impl IntoResponse {
    Json(json!(Vec::<String>::new()))
}

async fn st_args_put(Json(_body): Json<Value>) -> impl IntoResponse {
    Json(json!({"ok": true}))
}

async fn deploy_stub() -> impl IntoResponse {
    Json(json!({"stub": true, "message": "DeployManager not yet implemented"}))
}
async fn deploy_status_stub() -> impl IntoResponse { Json(json!({"busy": false, "stub": true})) }
async fn deploy_log_stub() -> impl IntoResponse { Json(json!({"log": "", "stub": true})) }
async fn deploy_protocols_stub() -> impl IntoResponse { Json(json!({"protocols": [], "stub": true})) }

async fn platform_caps(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let socks5_port = *state.socks5_port.read();
    Json(json!({
        "canShowWebView": false,
        "canRunTun": true,
        "canDeploy": false,
        "canAutoUpdate": false,
        "canSendNotifications": true,
        "canOpenExternalUrl": true,
        "os": std::env::consts::OS,
        "platform": "desktop",
        "socks5Port": socks5_port,
    }))
}

#[derive(Deserialize)]
struct OpenUrlBody { url: String }

async fn platform_open_url(Json(body): Json<OpenUrlBody>) -> impl IntoResponse {
    #[cfg(target_os = "linux")]
    { let _ = std::process::Command::new("xdg-open").arg(&body.url).spawn(); }
    #[cfg(target_os = "windows")]
    { let _ = std::process::Command::new("cmd").args(["/c", "start", "", &body.url]).spawn(); }
    Json(json!({"ok": true}))
}

#[derive(Deserialize)]
struct NotifyBody { title: String, body: String }

async fn platform_notify(Json(body): Json<NotifyBody>) -> impl IntoResponse {
    #[cfg(target_os = "linux")]
    { let _ = std::process::Command::new("notify-send").args([&body.title, &body.body]).spawn(); }
    #[cfg(target_os = "windows")]
    {
        let script = format!(
            "[reflection.assembly]::loadwithpartialname('System.Windows.Forms'); \
             [System.Windows.Forms.MessageBox]::Show('{}', '{}')",
            body.body.replace('\'', " "), body.title.replace('\'', " ")
        );
        let _ = std::process::Command::new("powershell")
            .args(["-NoProfile", "-Command", &script]).spawn();
    }
    Json(json!({"ok": true}))
}

#[derive(Deserialize)]
struct OpenPathBody { path: String }

async fn platform_open_path(Json(body): Json<OpenPathBody>) -> impl IntoResponse {
    #[cfg(target_os = "linux")]
    { let _ = std::process::Command::new("xdg-open").arg(&body.path).spawn(); }
    #[cfg(target_os = "windows")]
    { let _ = std::process::Command::new("explorer").arg(&body.path).spawn(); }
    Json(json!({"ok": true}))
}

#[derive(Deserialize)]
struct ShareBody {
    #[serde(default)] text: Option<String>,
    #[serde(default, rename = "filePath")] file_path: Option<String>,
}

async fn platform_share(Json(_body): Json<ShareBody>) -> impl IntoResponse {
    Json(json!({"ok": true}))
}

async fn debug_state(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let logs = state.logs_snapshot();
    let settings = state.settings.read().clone();
    let selected = state.selected_config.read().clone();
    let vpn_status = state.vpn.status(selected.as_ref().map(|c| c.id).unwrap_or(0));
    let socks5_port = *state.socks5_port.read();
    Json(json!({
        "settings": settings,
        "selectedConfig": selected,
        "vpnStatus": vpn_status,
        "logCount": logs.len(),
        "appDir": state.app_dir.to_string_lossy(),
        "luaAvailable": state.lua().is_some(),
        "socks5Port": socks5_port,
    }))
}

async fn debug_echo(Json(body): Json<Value>) -> impl IntoResponse { Json(body) }

async fn debug_config(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(json!({
        "appDir": state.app_dir.to_string_lossy(),
        "configsPath": state.configs_path.to_string_lossy(),
        "settingsPath": state.settings_path.to_string_lossy(),
        "logsPath": state.logs_path.to_string_lossy(),
        "tokenPath": state.token_path.to_string_lossy(),
        "corePath": state.core_path.to_string_lossy(),
        "luaAvailable": state.lua().is_some(),
    }))
}

async fn debug_reload(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    if let Ok(data) = std::fs::read_to_string(&state.settings_path) {
        if let Ok(mut s) = serde_json::from_str::<crate::settings::Settings>(&data) {
            s.normalize();
            *state.settings.write() = s;
        }
    }
    Json(json!({"ok": true}))
}

async fn debug_lua(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(json!({
        "available": state.lua().is_some(),
        "smarttunnel_running": *state.smarttunnel_running.lock(),
    }))
}

#[derive(Deserialize)]
struct LuaEvalBody { code: String }

async fn debug_lua_eval(
    State(state): State<Arc<AppState>>,
    Json(body): Json<LuaEvalBody>,
) -> axum::response::Response {
    let lua = match state.lua() {
        Some(l) => l,
        None => return err(500, "lua not initialized"),
    };
    match lua.eval_str(&body.code) {
        Ok(v) => Json(json!({"ok": true, "result": v})).into_response(),
        Err(e) => err(500, format!("lua error: {e:#}")),
    }
}

fn err(code: u16, msg: impl Into<String>) -> axum::response::Response {
    let status = StatusCode::from_u16(code).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    (status, Json(json!({"error": msg.into(), "code": code}))).into_response()
}
