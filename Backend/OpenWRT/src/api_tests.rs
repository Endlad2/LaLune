use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
    response::Response,
    Router,
};
use serde_json::{json, Value};
use std::{os::unix::fs::PermissionsExt, path::PathBuf, sync::Arc};
use tower::ServiceExt;

struct Fixture {
    dir: PathBuf,
    app: Option<Router>,
}

impl Fixture {
    async fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("lalune-panel-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let state = Arc::new(crate::state::AppState::new_in(dir.clone()).await.unwrap());
        Self { dir, app: Some(crate::api::router(state)) }
    }

    async fn send(&self, method: &str, uri: &str, payload: Value) -> Response {
        self.app.as_ref().unwrap().clone().oneshot(Request::builder()
            .method(method).uri(uri).header("content-type", "application/json")
            .body(Body::from(payload.to_string())).unwrap()).await.unwrap()
    }

    async fn json(&self, method: &str, uri: &str, payload: Value, status: StatusCode) -> Value {
        let response = self.send(method, uri, payload).await;
        assert_eq!(response.status(), status);
        let bytes = to_bytes(response.into_body(), 256 * 1024).await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        drop(self.app.take());
        assert_eq!(self.dir.canonicalize().unwrap().parent().unwrap(),
            std::env::temp_dir().canonicalize().unwrap());
        std::fs::remove_dir_all(&self.dir).unwrap();
    }
}

#[tokio::test]
async fn panel_assets_are_served_with_same_origin_policy() {
    let fixture = Fixture::new().await;
    for (path, kind) in [
        ("/panel", "text/html"),
        ("/panel/", "text/html"),
        ("/panel/panel.css", "text/css"),
        ("/panel/panel.js", "text/javascript"),
    ] {
        let response = fixture.send("GET", path, Value::Null).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert!(response.headers()["content-type"].to_str().unwrap().starts_with(kind));
        assert_eq!(response.headers()["cache-control"], "no-store");
        assert!(response.headers()["content-security-policy"].to_str().unwrap().contains("connect-src 'self'"));
    }
}

#[tokio::test]
async fn panel_can_import_profile_and_validate_auto_api_without_network() {
    let fixture = Fixture::new().await;
    let imported = fixture.json("POST", "/configs", json!({
        "protocol": "CSQTT 2.5.1",
        "name": "Example",
        "link": "csqtt://connect?v=2&host=192.0.2.2&peer=46000&password=fixture-password&hashes=a+b",
    }), StatusCode::OK).await;
    let id = imported["id"].as_i64().unwrap();
    fixture.json("PUT", "/configs/selected", json!({"id": id}), StatusCode::OK).await;
    let config = fixture.json("GET", "/configs/selected", Value::Null, StatusCode::OK).await;
    assert_eq!(config["protocol"], "CSQTT");
    assert_eq!(config["name"], "Example");
    assert_eq!(config["peer"], "192.0.2.2:46000");
    fixture.json("POST", "/configs", json!({"protocol":"PaperFlux","peer":"192.0.2.2:46000"}), StatusCode::BAD_REQUEST).await;
    fixture.json("PATCH", "/settings", json!({"authMode":"autoApi"}), StatusCode::OK).await;
    fixture.json("POST", "/vpn/connect", json!({"configId":id}), StatusCode::BAD_REQUEST).await;
    fixture.json("POST", "/vk/token/submit", json!({"token":" "}), StatusCode::BAD_REQUEST).await;
    fixture.json("POST", "/vk/token/submit", json!({"token":"fixture-vk-token"}), StatusCode::OK).await;
    let token = fixture.json("GET", "/vk/token/state", Value::Null, StatusCode::OK).await;
    assert_eq!(token["hasToken"], true);
    assert!(!token.to_string().contains("fixture-vk-token"));
    let path = fixture.dir.join("token.json");
    assert_eq!(std::fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
}
