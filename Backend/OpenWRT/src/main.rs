// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune backend для OpenWRT (armsr/armv8).
//
// Отличия от Desktop:
//   * Bind на 0.0.0.0:1062 (LAN-доступ).
//   * Ядра CSQTT / CSQTTR / CSQTT 2.1.9 встроены в release backend.
//   * Lua-рантайм (SmartTunnel + csqtt_decode) — mlua 5.4.
//   * csqtt-link как библиотека для парсинга csqtt:// ссылок.

mod api;
mod bundled_cores;
mod config;
mod core_logs;
mod core_manager;
mod csqtt_link_bridge;
mod events;
mod lua_runtime;
mod panel;
mod settings;
mod socks5;
mod state;
mod vk;
mod vpn;

#[cfg(test)]
mod api_tests;

#[path = "../../linux_core.rs"]
mod linux_core;
#[path = "../../linux_tun.rs"]
mod linux_tun;

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Result;
use tokio::net::TcpListener;

use crate::state::AppState;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info"),
    )
    .format_timestamp_millis()
    .init();

    log::info!("LaLune OpenWRT backend starting...");

    let state = Arc::new(AppState::new().await?);
    let log_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(2));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
            log_state.flush_log_history().await;
        }
    });

    // Инициализируем Lua-рантайм (SmartTunnel + csqtt_decode).
    if let Err(e) = state.init_lua() {
        log::error!("[LUA] init failed: {e:#}");
    } else {
        log::info!("[LUA] runtime initialized");
    }

    state.maybe_autostart_smarttunnel().await;

    let app = api::router(state.clone());

    let addr = SocketAddr::from(([0, 0, 0, 0], 1062));
    let listener = TcpListener::bind(addr).await?;
    log::info!("API listening on http://{}", addr);

    let state_for_shutdown = state.clone();
    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            shutdown_signal(state_for_shutdown).await;
        })
        .await?;

    log::info!("LaLune OpenWRT backend stopped.");
    Ok(())
}

async fn shutdown_signal(state: Arc<AppState>) {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
        _ = state.shutdown_notified() => {},
    }

    log::info!("Shutdown signal received.");
    state.cleanup().await;
}
