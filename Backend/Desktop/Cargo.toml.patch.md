# Патч Backend/Desktop/Cargo.toml

Добавить `base64` в `[dependencies]`:

```toml
[dependencies]
# ... существующие ...
base64 = "0.22"
```

## Причина

`src/config.rs` использует `base64` для `freeturn://<base64url(json)>`:

- `use base64::engine::general_purpose::{URL_SAFE_NO_PAD, URL_SAFE};`
- `use base64::Engine as _;`
- `fn decode_base64url(s: &str) -> Result<Vec<u8>, base64::DecodeError>`

Без `base64 = "0.22"` в `Cargo.toml` компилятор падает с
`E0433: cannot find module or crate base64`.

## Проверка

```
cd Backend/Desktop
cargo build --release
```

## Заодно warning'и (не блокируют сборку)

### `src/protocol.rs:305` — `unused variable: i`

В `build_freeturn_args` цикл:

```
for (i, arg) in args.iter().enumerate() {
    if skip_next { skip_next = false; continue; }
    if arg == "-listen" {
        skip_next = true;
        continue;
    }
    final_args.push(arg.clone());
}
```

`i` не используется. Заменить на:

```
for arg in args.iter() {
```

или (если хочешь сохранить enumerate):

```
for (_, arg) in args.iter().enumerate() {
```

или проще — через `filter`:

```
let mut final_args = Vec::new();
let mut skip_next = false;
for arg in args.iter() {
    if skip_next { skip_next = false; continue; }
    if arg == "-listen" {
        skip_next = true;
        continue;
    }
    final_args.push(arg.clone());
}
```

### `src/vpn.rs:395` — `unused variable: events_b`

В `start_tun` (Windows):

```
let events_b = events.clone();
```

Переменная не используется. Заменить на:

```
let _events_b = events.clone();
```

или удалить строку, если она больше нигде не нужна.

</BDS:create_file>

<BDS:create_file fileName="Backend/OpenWRT/Cargo.toml">

```toml
[package]
name = "lalune-openwrt-backend"
version = "0.6.0"
edition = "2021"
description = "LaLune backend daemon for OpenWRT (axum + tun), binds 0.0.0.0:1062"
license = "PolyForm-Noncommercial-1.0.0"
authors = ["Endlad7373 <vladut7373@gmail.com>"]

[[bin]]
name = "lalune-openwrt-backend"
path = "src/main.rs"

[dependencies]
tokio = { version = "1", features = ["full"] }
axum = { version = "0.7", features = ["macros", "json"] }
tower = "0.5"
tower-http = { version = "0.6", features = ["cors", "trace"] }

serde = { version = "1", features = ["derive"] }
serde_json = "1"

uuid = { version = "1", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
dirs = "5"
anyhow = "1"
thiserror = "1"
log = "0.4"
env_logger = "0.11"
hostname = "0.4"
num_cpus = "1"

futures = "0.3"
tokio-stream = "0.1"
async-stream = "0.3"

parking_lot = "0.12"

reqwest = { version = "0.12", default-features = false, features = ["json", "stream", "rustls-tls"] }

tun = "0.6"

rusqlite = { version = "0.31", features = ["bundled"] }

regex = "1"

# base64: используется в config.rs для freeturn:// (если OpenWRT поддерживает)
base64 = "0.22"

# Lua 5.4 (встроенный интерпретатор, без внешних .so)
mlua = { version = "0.9", features = ["lua54", "vendored", "send"] }

# zlib inflate для Lua-модуля zlib
flate2 = "1"

# csqtt-link: AES-256-GCM декодер csqtt:// ссылок (локальный крейт)
csqtt-link = { path = "../../Core/csqtt-link" }

[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
strip = true
panic = "abort"

