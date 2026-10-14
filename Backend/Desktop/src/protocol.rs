// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Protocol registry: CSQTT и PaperFlux.
//
// Каждый протокол умеет:
//   * назвать себя (id, displayName, repo, coreAsset для GitHub Releases);
//   * собрать аргументы запуска ядра из ConfigItem + Settings;
//   * сказать, какие настройки показывать в UI (набор ключей);
//   * описать "placeholder" для диалога добавления конфига.

use serde::{Deserialize, Serialize};

use crate::config::ConfigItem;
use crate::settings::Settings;

pub const CORE_LISTEN_PORT: u16 = 52230;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum ProtocolKind {
    Csqtt,
    PaperFlux,
}

impl ProtocolKind {
    pub fn from_id(s: &str) -> Option<Self> {
        match s.trim().to_ascii_uppercase().as_str() {
            "CSQTT" => Some(Self::Csqtt),
            "PAPERFLUX" | "OPENFLUX" => Some(Self::PaperFlux),
            _ => None,
        }
    }

    pub fn id(&self) -> &'static str {
        match self {
            Self::Csqtt => "CSQTT",
            Self::PaperFlux => "PaperFlux",
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Csqtt => "CSQTT (VK Calls)",
            Self::PaperFlux => "PaperFlux (Docs)",
        }
    }

    pub fn repo(&self) -> &'static str {
        match self {
            Self::Csqtt => "Endlad2/csqtt-core",
            Self::PaperFlux => "Endlad2/PaperFlux-core",
        }
    }

    pub fn description(&self) -> &'static str {
        match self {
            Self::Csqtt => "Оригинальный протокол на базе VK Calls, TURN и WRAP.",
            Self::PaperFlux => "Пробрасывает трафик через облачные документы (Yandex, Mail, OneMe и др.).",
        }
    }

    /// Имя ассета в GitHub Releases для текущей ОС/архитектуры.
    pub fn core_asset(&self) -> &'static str {
        match self {
            Self::Csqtt => crate::core_manager::csqtt_asset_name(),
            Self::PaperFlux => crate::core_manager::paperflux_asset_name(),
        }
    }

    /// Имя файла, под которым ядро кладётся в app_dir.
    pub fn local_filename(&self) -> &'static str {
        match self {
            Self::Csqtt => crate::core_manager::csqtt_local_filename(),
            Self::PaperFlux => crate::core_manager::paperflux_local_filename(),
        }
    }
}

/// Один поддерживаемый протокол.
pub fn supported_protocols() -> Vec<serde_json::Value> {
    [ProtocolKind::Csqtt, ProtocolKind::PaperFlux]
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

/// Набор ключей настроек, релевантных протоколу.
/// UI использует это, чтобы показывать/скрывать поля.
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
            // Общие (у PaperFlux — только transport + протокольные)
            "pfTransport", "pfUrl", "pfUrls", "pfVolgaUrl",
            "pfMode", "pfSocks5", "pfTcpRecovery",
            "pfRelayUrl", "pfRelayToken", "pfRelayUser", "pfRelaySession",
            "pfMaxToken", "pfMaxUid",
            "workers", "shareVpn", "showCoreLogs",
        ],
    }
}

// ============================================================
//  Build args
// ============================================================

/// Собирает аргументы запуска ядра под конкретный протокол.
///
/// ВАЖНО: PaperFlux всегда запускается с `--client` (см. ТЗ).
/// CSQTT — как раньше, через `-n`, `-vk`, и т.д.
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
    }
}

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

    let auth_mode = if settings.auth_mode.is_empty() {
        "manual".to_string()
    } else {
        settings.auth_mode.clone()
    };
    let is_auto_vk = auth_mode == "autoVk";

    let hash_mode = if is_auto_vk { "auto_js" } else { "manual" };
    let vk_auth_mode = if is_auto_vk {
        "auto_js"
    } else if settings.vk_auth_mode.is_empty() {
        "vkcalls"
    } else {
        settings.vk_auth_mode.as_str()
    };

    let workers = settings.workers.clamp(
        crate::settings::MIN_WORKERS,
        crate::settings::MAX_WORKERS,
    );

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
        "--device-id".into(), settings.device_id.clone(),
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

    if !settings.turn_host.is_empty() {
        args.push("--turn".into());
        args.push(settings.turn_host.clone());
    }
    if !settings.turn_port.is_empty() {
        args.push("--port".into());
        args.push(settings.turn_port.clone());
    }
    if settings.allow_hash_redistribution {
        args.push("--allow-hash-redistribution".into());
    }
    if settings.validate_vk_hashes {
        args.push("--validate-vk-hashes".into());
    }

    args
}

fn build_paperflux_args(
    config: &ConfigItem,
    settings: &Settings,
    listen_port: u16,
) -> Vec<String> {
    let mut args: Vec<String> = Vec::with_capacity(32);

    // --- Всегда client ---
    args.push("--client".into());

    // --- Идентичность профиля ---
    if !config.profile_id.is_empty() {
        args.push("--profile-id".into());
        args.push(config.profile_id.clone());
    }
    if !config.profile_token.is_empty() {
        args.push("--profile-token".into());
        args.push(config.profile_token.clone());
    }
    // client-ip: если в конфиге не задан — 10.10.10.2 (дефолт).
    let client_ip = if config.client_ip.is_empty() {
        settings.pf_client_ip.clone()
    } else {
        config.client_ip.clone()
    };
    let client_ip = if client_ip.is_empty() { "10.10.10.2".into() } else { client_ip };
    args.push("--client-ip".into());
    args.push(client_ip);

    // --- Транспорт ---
    let transport = if settings.pf_transport.is_empty() {
        if config.transport.is_empty() { "yandex".to_string() } else { config.transport.clone() }
    } else {
        settings.pf_transport.clone()
    };
    args.push("--transport".into());
    args.push(transport.clone());

    if settings.pf_session {
        args.push("--session".into());
    }
    if !settings.pf_tcp_recovery.is_empty() {
        args.push("--tcp-recovery".into());
        args.push(settings.pf_tcp_recovery.clone());
    }

    // --- Документы и URL ---
    // Для document-транспортов (yandex/boards/mailru/oneme/cupsonline) используем
    // config.url (из ссылки) или settings.pf_url.
    let url = if !config.url.is_empty() {
        config.url.clone()
    } else {
        settings.pf_url.clone()
    };
    if !url.is_empty() {
        args.push("--url".into());
        args.push(url);
    }

    let urls = if !config.urls.is_empty() { config.urls.clone() } else { settings.pf_urls.clone() };
    if !urls.is_empty() {
        args.push("--urls".into());
        args.push(urls);
    }

    let volga = if !config.volga_url.is_empty() {
        config.volga_url.clone()
    } else {
        settings.pf_volga_url.clone()
    };
    if !volga.is_empty() {
        args.push("--volga-url".into());
        args.push(volga);
    }

    // --- Сеть и выход ---
    // Всегда proxy + SOCKS5 (TUN оборачиваем отдельно вокруг SOCKS).
    args.push("--mode".into());
    args.push("proxy".into());
    args.push("--socks5".into());
    args.push(format!("127.0.0.1:{}", listen_port));

    if !settings.pf_auth_service.is_empty() {
        args.push("--auth-service".into());
        args.push(settings.pf_auth_service.clone());
    }
    if !settings.pf_ipc_socket.is_empty() {
        args.push("--ipc-socket".into());
        args.push(settings.pf_ipc_socket.clone());
    }
    if !settings.pf_tun_fd_sock.is_empty() {
        args.push("--tun-fd-sock".into());
        args.push(settings.pf_tun_fd_sock.clone());
    }
    if !settings.pf_packet_sock.is_empty() {
        args.push("--packet-sock".into());
        args.push(settings.pf_packet_sock.clone());
    }

    // --- Групповой exit ---
    if !settings.pf_exit_profiles.is_empty() {
        args.push("--exit-profiles".into());
        args.push(settings.pf_exit_profiles.clone());
    }
    if !settings.pf_exit_stats.is_empty() {
        args.push("--exit-stats".into());
        args.push(settings.pf_exit_stats.clone());
    }
    if !settings.pf_exit_cookies.is_empty() {
        args.push("--exit-cookies".into());
        args.push(settings.pf_exit_cookies.clone());
    }

    // --- Relay V2 ---
    let relay_url = if !config.relay_url.is_empty() { config.relay_url.clone() } else { settings.pf_relay_url.clone() };
    if !relay_url.is_empty() {
        args.push("--relay-url".into());
        args.push(relay_url);
    }
    let relay_token = if !config.relay_token.is_empty() { config.relay_token.clone() } else { settings.pf_relay_token.clone() };
    if !relay_token.is_empty() {
        args.push("--relay-token".into());
        args.push(relay_token);
    }
    if settings.pf_relay_user > 0 {
        args.push("--relay-user".into());
        args.push(settings.pf_relay_user.to_string());
    }
    if !settings.pf_relay_session.is_empty() {
        args.push("--relay-session".into());
        args.push(settings.pf_relay_session.clone());
    }

    // --- MAX / OneMe ---
    let max_token = if !config.max_token.is_empty() { config.max_token.clone() } else { settings.pf_max_token.clone() };
    if !max_token.is_empty() {
        args.push("--maxToken".into());
        args.push(max_token);
    }
    let max_uid = if !config.max_uid.is_empty() { config.max_uid.clone() } else { settings.pf_max_uid.clone() };
    if !max_uid.is_empty() {
        args.push("--maxUid".into());
        args.push(max_uid);
    }

    args
}

fn read_vk_token_for_core() -> Option<String> {
    let dir = crate::state::app_dir().ok()?;
    crate::vk::read_token(&dir)
}

// ============================================================
//  Placeholder для диалога «+»
// ============================================================

/// Плейсхолдер для ссылки. НЕ должен содержать реальных данных —
/// только визуальная подсказка формата.
pub fn link_placeholder(kind: ProtocolKind) -> &'static str {
    match kind {
        ProtocolKind::Csqtt => {
            "csqtt://connect?v=2&host=...&peer=...&password=...&hashes=h1+h2"
        }
        ProtocolKind::PaperFlux => {
            "paperflux://config?v=1&id=...&name=...&server=...&ip=...&transport=...&doc=...&token=...&volga=..."
        }
    }
}
