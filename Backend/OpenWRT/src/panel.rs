// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use std::sync::Arc;

use axum::{response::IntoResponse, routing::get, Router};

use crate::state::AppState;

const CSP: &str = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/panel", get(index))
        .route("/panel/", get(index))
        .route("/panel/panel.css", get(css))
        .route("/panel/panel.js", get(js))
}

async fn index() -> impl IntoResponse {
    asset("text/html; charset=utf-8", include_str!("panel/index.html"))
}

async fn css() -> impl IntoResponse {
    asset("text/css; charset=utf-8", include_str!("panel/panel.css"))
}

async fn js() -> impl IntoResponse {
    asset(
        "text/javascript; charset=utf-8",
        include_str!("panel/panel.js"),
    )
}

fn asset(content_type: &'static str, contents: &'static str) -> impl IntoResponse {
    (
        [
            ("content-type", content_type),
            ("cache-control", "no-store"),
            ("content-security-policy", CSP),
            ("referrer-policy", "no-referrer"),
            ("x-content-type-options", "nosniff"),
            ("x-frame-options", "DENY"),
        ],
        contents,
    )
}
