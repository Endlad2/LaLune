// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune backend для OpenWRT (armsr/armv8).
//
// Отличия от Desktop:
//   * Bind на 0.0.0.0:1062 (LAN-доступ).
//   * Ядро: ~/.la-lune/csqtt-client-aarch64 (фиксированное имя).
//
// Всё остальное — как в Desktop (см. Backend/Desktop/src/).

mod api;
mod config;
mod core_manager;
mod events;
mod settings;
mod state;
mod vk;
mod vpn;

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

    state.maybe_autostart_smarttunnel().await;

    let app = api::router(state.clone());

    // ВАЖНО: bind на 0.0.0.0, чтобы UI по LAN мог достучаться.
    // Порт 1062 — как у Desktop, чтобы API был идентичным.
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
