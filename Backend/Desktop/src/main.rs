// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune backend daemon (Windows/Linux).
// HTTP API на 127.0.0.1:1062.

mod api;
mod config;
mod core_manager;
mod csqtt_link_bridge;
mod events;
mod lua_runtime;
mod protocol;
mod settings;
mod socks5;
mod state;
mod vk;
mod vpn;

#[cfg(target_os = "windows")]
mod wintun;

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Result;
use tokio::net::TcpListener;

use crate::state::AppState;

#[tokio::main]
async fn main() -> Result<()> {
    // По умолчанию — debug, чтобы видеть все наши [PARSE] / [CSQTT-LINK] / [LUA] логи.
    // Переопределяется переменной RUST_LOG (например RUST_LOG=info).
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("debug"),
    )
    .format_timestamp_millis()
    .init();

    log::info!("LaLune backend starting (default log level = debug)...");
    log::info!("Set RUST_LOG=info to reduce noise, RUST_LOG=trace for more.");

    let state = Arc::new(AppState::new().await?);
    log::info!("AppState created, app_dir={}", state.app_dir.display());

    match state.init_lua() {
        Ok(_) => log::info!("[LUA] state.init_lua() OK"),
        Err(e) => log::error!("[LUA] state.init_lua() FAILED: {e:#}"),
    }

    state.maybe_autostart_smarttunnel().await;

    let app = api::router(state.clone());

    let addr = SocketAddr::from(([127, 0, 0, 1], 1062));
    let listener = TcpListener::bind(addr).await?;
    log::info!("API listening on http://{}", addr);
    log::info!("Try: curl http://127.0.0.1:1062/debug/config");
    log::info!("Try: curl -X POST http://127.0.0.1:1062/configs -H 'Content-Type: application/json' -d '{{\"link\":\"csqtt://...\"}}'");

    let state_for_shutdown = state.clone();
    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            shutdown_signal(state_for_shutdown).await;
        })
        .await?;

    log::info!("LaLune backend stopped.");
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
