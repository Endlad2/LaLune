# Патч api.rs — не терять `wg_relay` при PUT/POST

`ConfigItem` (Rust) теперь содержит поля `obf_profile`, `obf_key`,
`mode`, `n`, `spc`, `client_id`, `dns_mode`, `dns_servers`, `vk_link`,
`wg_conf`, `wg_relay`. `api.rs` читает JSON body в `ConfigCreateBody`
и собирает `ConfigItem::default()` вручную — новые поля теряются.

## `ConfigCreateBody` — добавить поля

```rust
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
    // FreeTurn
    #[serde(rename = "obfProfile")] obf_profile: Option<String>,
    #[serde(rename = "obfKey")] obf_key: Option<String>,
    mode: Option<String>,
    n: Option<i64>,
    spc: Option<i64>,
    #[serde(rename = "clientId")] client_id: Option<String>,
    #[serde(rename = "dnsMode")] dns_mode: Option<String>,
    #[serde(rename = "dnsServers")] dns_servers: Option<String>,
    #[serde(rename = "vkLink")] vk_link: Option<String>,
    #[serde(rename = "wgConf")] wg_conf: Option<String>,
    #[serde(rename = "wgRelay")] wg_relay: Option<bool>,
}
```

## `body_to_item` — заполнить новые поля

```
fn body_to_item(body: ConfigCreateBody) -> Result<ConfigItem, String> {
    if let Some(link) = body.link.as_ref().filter(|l| !l.trim().is_empty()) {
        log::info!("[API] body_to_item: has link, calling parse_link");
        return parse_link(link).map_err(|e| {
            log::warn!("[API] body_to_item: parse_link FAILED: {:#}", e);
            e.to_string()
        });
    }
    log::info!("[API] body_to_item: no link, using raw fields");

    let mut c = ConfigItem::default();
    c.protocol = body.protocol.unwrap_or_else(|| "CSQTT".into());
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
    // FreeTurn
    c.obf_profile = body.obf_profile.unwrap_or_default();
    c.obf_key = body.obf_key.unwrap_or_default();
    c.mode = body.mode.unwrap_or_default();
    c.n = body.n.unwrap_or(0);
    c.spc = body.spc.unwrap_or(0);
    c.client_id = body.client_id.unwrap_or_default();
    c.dns_mode = body.dns_mode.unwrap_or_default();
    c.dns_servers = body.dns_servers.unwrap_or_default();
    c.vk_link = body.vk_link.unwrap_or_default();
    c.wg_conf = body.wg_conf.unwrap_or_default();
    c.wg_relay = body.wg_relay.unwrap_or(false);

    if c.name.is_empty() {
        c.name = if c.peer.is_empty() { c.server.clone() } else { c.peer.clone() };
    }
    Ok(c)
}
```

## `configs_parse` — залогировать `wg_relay`

```
async fn configs_parse(Json(body): Json<ParseBody>) -> impl IntoResponse {
    log::info!("[API] POST /configs/parse link_len={}", body.link.len());
    match parse_link(&body.link) {
        Ok(c) => {
            log::info!(
                "[API] /configs/parse OK: protocol={} peer={} name={} wg_relay={}",
                c.protocol, c.peer, c.name, c.wg_relay
            );
            Json(json!(c)).into_response()
        }
        Err(e) => {
            log::warn!("[API] /configs/parse FAILED: {:#}", e);
            err(400, e.to_string())
        }
    }
}
```

## Проверка

```
# Desktop, запущенный с RUST_LOG=debug
$link = 'freeturn://eyJ2IjoxLCJwcm92aWRlciI6InZrIiwicGVlciI6IjMxLjc3LjE0OC4yMDM6NTczNzMi...'
Invoke-RestMethod -Uri "http://127.0.0.1:1062/configs/parse" `
  -Method POST -ContentType "application/json" `
  -Body (@{ link = $link } | ConvertTo-Json)

# Ожидаем:
# protocol    = FreeTurn
# peer        = 31.77.148.203:57373
# name        = Users
# obfProfile  = rtpopus3
# wgRelay     = True
```

Если `[PARSE][FREETURN] missing 'peer'` — payload не расшифровался
(проверь padding/wrap). Если `[PARSE][FREETURN] base64 decode: ...` —
неверный base64url.

</BDS:create_file>

<BDS:create_file fileName="Backend/Desktop/src/protocol.rs">

```rust
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Protocol registry + build_args для csqtt/paperflux/freeturn.

use serde::{Deserialize, Serialize};
use crate::config::{is_relay_topology, strip_wg_endpoint, ConfigItem};
use crate::settings::Settings;

pub const CORE_LISTEN_PORT: u16 = 5399;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum ProtocolKind {
    Csqtt,
    PaperFlux,
    FreeTurn,
}

impl ProtocolKind {
    pub fn from_id(s: &str) -> Option<Self> {
        match s.trim().to_ascii_uppercase().as_str() {
            "CSQTT" => Some(Self::Csqtt),
            "PAPERFLUX" | "OPENFLUX" => Some(Self::PaperFlux),
            "FREETURN" => Some(Self::FreeTurn),
            _ => None,
        }
    }

    pub fn id(&self) -> &'static str {
        match self {
            Self::Csqtt => "CSQTT",
            Self::PaperFlux => "PaperFlux",
            Self::FreeTurn => "FreeTurn",
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Csqtt => "CSQTT (VK Calls)",
            Self::PaperFlux => "PaperFlux (Docs)",
            Self::FreeTurn => "FreeTurn (TURN relay)",
        }
    }

    pub fn repo(&self) -> &'static str {
        match self {
            Self::Csqtt => "Endlad2/csqtt-core",
            Self::PaperFlux => "Endlad2/PaperFlux-core",
            Self::FreeTurn => "hackdiaz-dev/free-turn-proxy",
        }
    }

    pub fn description(&self) -> &'static str {
        match self {
            Self::Csqtt => "Оригинальный протокол на базе VK Calls, TURN и WRAP.",
            Self::PaperFlux => "Пробрасывает трафик через облачные документы (Yandex, Mail, OneMe и др.).",
            Self::FreeTurn => "Прокси-клиент через TURN-реле с обфускацией RTP/OPUS.",
        }
    }

    pub fn core_asset(&self) -> &'static str {
        match self {
            Self::Csqtt => crate::core_manager::csqtt_asset_name(),
            Self::PaperFlux => crate::core_manager::paperflux_asset_name(),
            Self::FreeTurn => crate::core_manager::freeturn_asset_name(),
        }
    }

    pub fn local_filename(&self) -> &'static str {
        match self {
            Self::Csqtt => crate::core_manager::csqtt_local_filename(),
            Self::PaperFlux => crate::core_manager::paperflux_local_filename(),
            Self::FreeTurn => crate::core_manager::freeturn_local_filename(),
        }
    }
}

pub fn supported_protocols() -> Vec<serde_json::Value> {
    [ProtocolKind::Csqtt, ProtocolKind::PaperFlux, ProtocolKind::FreeTurn]
        .into_iter()
        .map(|p| {
            serde_json::json!({
                "id": p.id(),
                "displayName": p.display_name(),
                "repo": p.repo(),
                "realtime": true,
                "description": p.description(),
                "coreAsset": p.core_asset(),
            })
        })
        .collect()
}

pub fn settings_keys_for(kind: ProtocolKind) -> Vec<&'static str> {
    match kind {
        ProtocolKind::Csqtt => vec![
            "peer", "vkHashes", "password", "workers", "autoApiWorkers",
            "authMode", "obfs", "fingerprint", "clientIds",
            "captchaMode", "vkAuthMode", "turnTransport",
            "allowHashRedistribution", "validateVkHashes",
            "shareVpn", "showCoreLogs",
        ],
        ProtocolKind::PaperFlux => vec![
            "pfTransport", "pfUrl", "pfUrls", "pfVolgaUrl",
            "pfMode", "pfSocks5", "pfTcpRecovery",
            "pfRelayUrl", "pfRelayToken", "pfRelayUser", "pfRelaySession",
            "pfMaxToken", "pfMaxUid",
            "workers", "shareVpn", "showCoreLogs",
        ],
        ProtocolKind::FreeTurn => vec![
            "ftLink", "ftKey", "ftCid",
            "ftProvider", "ftTransport", "ftMode", "ftBond", "ftObf",
            "ftN", "ftSpc", "ftListen", "ftDns", "ftDnss", "ftMcap",
            "ftKcp", "ftWgConf",
            "shareVpn", "showCoreLogs",
        ],
    }
}

pub fn build_args(
    config: &ConfigItem,
    settings: &Settings,
    listen_port: u16,
) -> Vec<String> {
    let kind = ProtocolKind::from_id(&config.protocol)
        .unwrap_or(ProtocolKind::Csqtt);

    match kind {
        ProtocolKind::Csqtt => build_csqtt_args(config, settings, listen_port),
        ProtocolKind::PaperFlux => build_paperflux_args(config, settings, listen_port),
        ProtocolKind::FreeTurn => build_freeturn_args(config, settings, listen_port),
    }
}

// -------- CSQTT --------

fn build_csqtt_args(
    config: &ConfigItem,
    settings: &Settings,
    listen_port: u16,
) -> Vec<String> {
    let normalized = config.hashes.replace([' ', '\t', '\n', '\r'], ",");
    let clean: Vec<String> = normalized
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .take(6)
        .collect();
    let hashes = if clean.is_empty() { String::new() } else { clean.join(",") };

    let auth_mode = if settings.auth_mode.is_empty() { "manual".to_string() } else { settings.auth_mode.clone() };
    let is_auto_vk = auth_mode == "autoVk";

    let hash_mode = if is_auto_vk { "auto_js" } else { "manual" };
    let vk_auth_mode = if is_auto_vk { "auto_js" } else if settings.vk_auth_mode.is_empty() { "vkcalls" } else { settings.vk_auth_mode.as_str() };

    let workers = settings.workers.clamp(crate::settings::MIN_WORKERS, crate::settings::MAX_WORKERS);

    let mut args: Vec<String> = vec![
        "--peer".into(), config.peer.clone(),
        "--password".into(), config.password.clone(),
        "--vk-hash-mode".into(), hash_mode.into(),
        "--vk-auth-mode".into(), vk_auth_mode.into(),
        "--listen".into(), format!("127.0.0.1:{}", listen_port),
        "-n".into(), workers.to_string(),
        "--obfs".into(), settings.obfs.clone(),
        "--fingerprint".into(), settings.fingerprint.clone(),
        "--client-ids".into(), settings.client_ids.clone(),
        "--captcha-mode".into(), settings.captcha_mode.clone(),
        "--turn-transport".into(), settings.turn_transport.clone(),
    ];

    if !is_auto_vk {
        args.push("--vk".into());
        args.push(hashes);
    }
    if is_auto_vk {
        if let Some(token) = read_vk_token_for_core() {
            args.push("--token".into());
            args.push(token);
        }
    }
    if !settings.turn_host.is_empty() { args.push("--turn".into()); args.push(settings.turn_host.clone()); }
    if !settings.turn_port.is_empty() { args.push("--port".into()); args.push(settings.turn_port.clone()); }
    if settings.allow_hash_redistribution { args.push("--allow-hash-redistribution".into()); }
    if settings.validate_vk_hashes { args.push("--validate-vk-hashes".into()); }

    args
}

// -------- PaperFlux --------

fn build_paperflux_args(
    config: &ConfigItem,
    settings: &Settings,
    listen_port: u16,
) -> Vec<String> {
    let mut args: Vec<String> = Vec::with_capacity(32);
    args.push("--client".into());

    if !config.profile_id.is_empty() { args.push("--profile-id".into()); args.push(config.profile_id.clone()); }
    if !config.profile_token.is_empty() { args.push("--profile-token".into()); args.push(config.profile_token.clone()); }

    let client_ip = if config.client_ip.is_empty() { settings.pf_client_ip.clone() } else { config.client_ip.clone() };
    let client_ip = if client_ip.is_empty() { "10.10.10.2".into() } else { client_ip };
    args.push("--client-ip".into()); args.push(client_ip);

    let transport = if settings.pf_transport.is_empty() {
        if config.transport.is_empty() { "yandex".to_string() } else { config.transport.clone() }
    } else {
        settings.pf_transport.clone()
    };
    args.push("--transport".into()); args.push(transport.clone());

    if settings.pf_session { args.push("--session".into()); }
    if !settings.pf_tcp_recovery.is_empty() { args.push("--tcp-recovery".into()); args.push(settings.pf_tcp_recovery.clone()); }

    let url = if !config.url.is_empty() { config.url.clone() } else { settings.pf_url.clone() };
    if !url.is_empty() { args.push("--url".into()); args.push(url); }
    let urls = if !config.urls.is_empty() { config.urls.clone() } else { settings.pf_urls.clone() };
    if !urls.is_empty() { args.push("--urls".into()); args.push(urls); }
    let volga = if !config.volga_url.is_empty() { config.volga_url.clone() } else { settings.pf_volga_url.clone() };
    if !volga.is_empty() { args.push("--volga-url".into()); args.push(volga); }

    args.push("--mode".into()); args.push("proxy".into());
    args.push("--socks5".into()); args.push(format!("127.0.0.1:{}", listen_port));

    if !settings.pf_auth_service.is_empty() { args.push("--auth-service".into()); args.push(settings.pf_auth_service.clone()); }
    if !settings.pf_ipc_socket.is_empty() { args.push("--ipc-socket".into()); args.push(settings.pf_ipc_socket.clone()); }
    if !settings.pf_tun_fd_sock.is_empty() { args.push("--tun-fd-sock".into()); args.push(settings.pf_tun_fd_sock.clone()); }
    if !settings.pf_packet_sock.is_empty() { args.push("--packet-sock".into()); args.push(settings.pf_packet_sock.clone()); }
    if !settings.pf_exit_profiles.is_empty() { args.push("--exit-profiles".into()); args.push(settings.pf_exit_profiles.clone()); }
    if !settings.pf_exit_stats.is_empty() { args.push("--exit-stats".into()); args.push(settings.pf_exit_stats.clone()); }
    if !settings.pf_exit_cookies.is_empty() { args.push("--exit-cookies".into()); args.push(settings.pf_exit_cookies.clone()); }

    let relay_url = if !config.relay_url.is_empty() { config.relay_url.clone() } else { settings.pf_relay_url.clone() };
    if !relay_url.is_empty() { args.push("--relay-url".into()); args.push(relay_url); }
    let relay_token = if !config.relay_token.is_empty() { config.relay_token.clone() } else { settings.pf_relay_token.clone() };
    if !relay_token.is_empty() { args.push("--relay-token".into()); args.push(relay_token); }
    if settings.pf_relay_user > 0 { args.push("--relay-user".into()); args.push(settings.pf_relay_user.to_string()); }
    if !settings.pf_relay_session.is_empty() { args.push("--relay-session".into()); args.push(settings.pf_relay_session.clone()); }

    let max_token = if !config.max_token.is_empty() { config.max_token.clone() } else { settings.pf_max_token.clone() };
    if !max_token.is_empty() { args.push("--maxToken".into()); args.push(max_token); }
    let max_uid = if !config.max_uid.is_empty() { config.max_uid.clone() } else { settings.pf_max_uid.clone() };
    if !max_uid.is_empty() { args.push("--maxUid".into()); args.push(max_uid); }

    args
}

// -------- FreeTurn --------
//
// docs/flags.md upstream:
//   -listen <ip:port>           локальный UDP для WireGuard/Xray
//   -peer <host:port>           сервер VPS (обязательно)
//   -provider vk|direct         vk (TURN relay) | direct
//   -links <url1,url2>          VK-ссылки на звонок (обязательны для vk)
//   -link <url>                 (устар.) одна ссылка
//   -n <int>                    TURN-потоков
//   -streams-per-cred <int>     потоков на один кеш учёток
//   -transport tcp|udp          транспорт до TURN-реле
//   -mode udp|tcp               режим туннеля
//   -bond                       только -mode tcp
//   -obf-profile none|rtpopus|rtpopus2|rtpopus3
//   -obf-key <hex64>
//   -obf-timing <duration>
//   -dns-mode plain|doh|auto
//   -dns-servers <csv>
//   -client-id <string>
//   -platform desktop|mobile
//   -manual-captcha
//   -debug
//
// Backend LaLune запускает FreeTurn как relay-only процесс:
//   -listen 127.0.0.1:<CORE_LISTEN_PORT>   ← TUN-мост бэкенда
//   -peer <peer>
//   -provider vk|direct
//   -links <link> (если есть)
//   -n <n>  -streams-per-cred <spc>
//   -transport tcp|udp  -mode udp|tcp
//   -obf-profile rtpopus3 -obf-key <hex64>
//   -dns-mode auto
//   -client-id <cid>
//   -debug? (если settings.show_core_logs)
//
// Если в конфиге есть wg_conf, но wg_relay=true (Endpoint = 127.0.0.1:9000),
// это relay-топология: бэкенд сам поднимает TUN, встроенный WG не нужен.
// wg_conf игнорируется.
//
// Если wg_relay=false (Endpoint = внешний адрес), это встроенный WG.
// Бэкенд всё равно запускает FreeTurn в relay-only режиме (TUN поднимает
// Desktop/VpnService с UDP-мостом на CORE_LISTEN_PORT). Встроенный
// WG мы не используем: апстрим всё равно игнорирует Endpoint.
//
// Убираем из wg Endpoint — на случай, если кто-то (AAR на Android)
// попытается parseTunnelConfig.

fn build_freeturn_args(
    config: &ConfigItem,
    settings: &Settings,
    listen_port: u16,
) -> Vec<String> {
    let mut args: Vec<String> = Vec::with_capacity(32);

    // -listen: локальный UDP, куда ходит TUN-мост бэкенда.
    args.push("-listen".into());
    args.push(format!("127.0.0.1:{}", listen_port));

    // -peer
    if !config.peer.is_empty() {
        args.push("-peer".into());
        args.push(config.peer.clone());
    }

    // provider: vk по умолчанию, direct — если в конфиге прописано
    let provider = if config.mode.is_empty() && config.vk_link.is_empty() && settings.ft_link.is_empty() {
        "direct"
    } else {
        "vk"
    };
    args.push("-provider".into());
    args.push(provider.into());

    // -link / -links
    let link = if !config.vk_link.is_empty() {
        config.vk_link.clone()
    } else if !settings.ft_link.is_empty() {
        settings.ft_link.clone()
    } else {
        String::new()
    };
    if !link.is_empty() {
        args.push("-links".into());
        args.push(link);
    }

    // -n / -streams-per-cred
    let n = if config.n > 0 { config.n } else if settings.ft_n > 0 { settings.ft_n as i64 } else { 12 };
    let spc = if config.spc > 0 { config.spc } else if settings.ft_spc > 0 { settings.ft_spc as i64 } else { 12 };
    args.push("-n".into());
    args.push(n.to_string());
    args.push("-streams-per-cred".into());
    args.push(spc.to_string());

    // -transport
    let transport = if !config.transport.is_empty() {
        config.transport.clone()
    } else if !settings.ft_transport.is_empty() {
        settings.ft_transport.clone()
    } else {
        "tcp".to_string()
    };
    args.push("-transport".into());
    args.push(transport);

    // -mode
    let mode = if !config.mode.is_empty() {
        config.mode.clone()
    } else if !settings.ft_mode.is_empty() {
        settings.ft_mode.clone()
    } else {
        "udp".to_string()
    };
    args.push("-mode".into());
    args.push(mode.clone());

    // -bond: только mode=tcp
    if mode == "tcp" && settings.ft_bond {
        args.push("-bond".into());
    }

    // -obf-profile / -obf-key
    let obf = if !config.obf_profile.is_empty() {
        config.obf_profile.clone()
    } else if !settings.ft_obf.is_empty() {
        settings.ft_obf.clone()
    } else {
        "rtpopus3".to_string()
    };
    if obf != "none" {
        args.push("-obf-profile".into());
        args.push(obf);

        let key = if !config.obf_key.is_empty() {
            config.obf_key.clone()
        } else if !settings.ft_key.is_empty() {
            settings.ft_key.clone()
        } else {
            String::new()
        };
        if !key.is_empty() {
            args.push("-obf-key".into());
            args.push(key);
        }
    }

    // -dns-mode / -dns-servers
    let dns_mode = if !config.dns_mode.is_empty() {
        config.dns_mode.clone()
    } else if !settings.ft_dns.is_empty() {
        settings.ft_dns.clone()
    } else {
        "auto".to_string()
    };
    args.push("-dns-mode".into());
    args.push(dns_mode);

    let dns_servers = if !config.dns_servers.is_empty() {
        config.dns_servers.clone()
    } else if !settings.ft_dnss.is_empty() {
        settings.ft_dnss.clone()
    } else {
        String::new()
    };
    if !dns_servers.is_empty() {
        args.push("-dns-servers".into());
        args.push(dns_servers);
    }

    // -client-id
    let client_id = if !config.client_id.is_empty() {
        config.client_id.clone()
    } else if !settings.ft_cid.is_empty() {
        settings.ft_cid.clone()
    } else {
        String::new()
    };
    if !client_id.is_empty() {
        args.push("-client-id".into());
        args.push(client_id);
    }

    // -platform: desktop на Desktop-сборке
    args.push("-platform".into());
    args.push("desktop".into());

    // -manual-captcha
    if settings.ft_mcap {
        args.push("-manual-captcha".into());
    }

    // -debug: если пользователь просил показывать логи ядра
    if settings.show_core_logs {
        args.push("-debug".into());
    }

    // Встроенный WG (wg_relay=false) не используем: relay-only.
    // wg_conf хранится для будущего; strip_wg_endpoint() есть на случай,
    // если понадобится передавать его в AAR.
    let _ = &config.wg_conf;
    let _ = &config.wg_relay;
    let _ = is_relay_topology(&config.wg_conf);
    let _ = strip_wg_endpoint(&config.wg_conf);

    args
}

fn read_vk_token_for_core() -> Option<String> {
    let dir = crate::state::app_dir().ok()?;
    crate::vk::read_token(&dir)
}

pub fn link_placeholder(kind: ProtocolKind) -> &'static str {
    match kind {
        ProtocolKind::Csqtt => "csqtt://connect?v=2&host=...&peer=...&password=...&hashes=h1+h2",
        ProtocolKind::PaperFlux => "paperflux://config?v=1&id=...&name=...",
        ProtocolKind::FreeTurn => "freeturn://<base64url(json)>",
    }
}

