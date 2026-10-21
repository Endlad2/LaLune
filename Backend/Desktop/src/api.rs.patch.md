# Патч api.rs — добавить логи в POST /configs

В `Backend/Desktop/src/api.rs` найди `configs_create` и `configs_parse`,
добавь в начало обоих функций лог. В `configs_parse` — ещё и полный
ответ, чтобы в логе было видно, что именно вернулось.

## configs_parse — было

```rust
#[derive(Deserialize)]
struct ParseBody { link: String }

async fn configs_parse(Json(body): Json<ParseBody>) -> impl IntoResponse {
    match parse_link(&body.link) {
        Ok(c) => Json(json!(c)).into_response(),
        Err(e) => err(400, e.to_string()),
    }
}
```

## configs_parse — стало

```
#[derive(Deserialize)]
struct ParseBody { link: String }

async fn configs_parse(Json(body): Json<ParseBody>) -> impl IntoResponse {
    log::info!("[API] POST /configs/parse link_len={}", body.link.len());
    match parse_link(&body.link) {
        Ok(c) => {
            log::info!("[API] /configs/parse OK: protocol={} peer={} name={}",
                c.protocol, c.peer, c.name);
            Json(json!(c)).into_response()
        }
        Err(e) => {
            log::warn!("[API] /configs/parse FAILED: {:#}", e);
            err(400, e.to_string())
        }
    }
}
```

## configs_create — было

```
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
```

## configs_create — стало

```
async fn configs_create(
    State(state): State<Arc<AppState>>,
    Json(body): Json<ConfigCreateBody>,
) -> impl IntoResponse {
    log::info!("[API] POST /configs protocol={:?} link_len={}",
        body.protocol, body.link.as_deref().map(|s| s.len()).unwrap_or(0));

    let config = match body_to_item(body) {
        Ok(c) => c,
        Err(e) => {
            log::warn!("[API] /configs body_to_item FAILED: {}", e);
            return err(400, e);
        }
    };
    log::info!("[API] /configs parsed: protocol={} peer={} password_len={} hashes_len={} name={}",
        config.protocol, config.peer, config.password.len(),
        config.hashes.len(), config.name);

    match state.configs.insert(&config) {
        Ok(id) => {
            log::info!("[API] /configs INSERTED id={}", id);
            Json(json!({"id": id})).into_response()
        }
        Err(e) => {
            log::error!("[API] /configs insert FAILED: {:#}", e);
            err(500, e.to_string())
        }
    }
}
```

## body_to_item — добавить лог

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
    // ... остальное как было
}
```

</BDS:create_file>

<BDS:create_file fileName="README-DEBUG-LOGS.md">

```markdown
# Как увидеть, что не так с парсингом csqtt://

## Что изменено

Бэкенд теперь пишет **много** логов на уровне `info`/`warn`:

1. **`main.rs`** — `env_logger` по умолчанию `debug` (не `info`).
   Все `log::info!` и `log::debug!` из модулей видны без `RUST_LOG`.

2. **`config.rs`** — `parse_csqtt` логирует каждый шаг:
   - `[PARSE][CSQTT] === start ===`
   - `[PARSE][CSQTT] raw link = ...` (обрезанный, 60+12 символов)
   - `[PARSE][CSQTT] trying csqtt-link (AES-256-GCM)...`
   - `[PARSE][CSQTT] csqtt-link FAILED: <причина>` или `OK: host=... port=...`
   - `[PARSE][CSQTT] trying Lua (csqtt_decode.lua)...`
   - `[PARSE][CSQTT] Lua FAILED: <причина>` или `OK: peer=...`
   - `[PARSE][CSQTT] trying native fallback...`
   - `[PARSE][CSQTT] === all parsers failed ===` (если всё упало)

3. **`csqtt_link_bridge.rs`** — логирует вход и результат csqtt-link:
   - `[CSQTT-LINK] parse called, input_len=... starts_with_csqtt=...`
   - `[CSQTT-LINK] OK: host=... port=...` или `FAILED: <причина>`

4. **`lua_runtime.rs`** — логирует инициализацию каждого шага:
   - `[LUA] init: creating Lua 5.4 VM`
   - `[LUA] init: registering zlib.inflate`
   - `[LUA] init: loading csqtt_decode.lua from ...` (или `using builtin`)
   - `[LUA] init: csqtt_decode module registered`
   - `[LUA] init: SmartTunnel.lua executed`
   - `[LUA] install_api: all 9 methods registered`
   - `[LUA] on_load() OK`
   - `[LUA] === runtime initialized ===`

5. **`config.rs` ConfigStore** — логирует SQLite-операции:
   - `[CONFIG] insert: protocol=... peer=...`
   - `[CONFIG] inserted id=...`

## Как применить

### 1. Заменить файлы

- `Backend/Desktop/src/main.rs` — заменён (debug по умолчанию)
- `Backend/Desktop/src/config.rs` — заменён (щедрое логирование)
- `Backend/Desktop/src/csqtt_link_bridge.rs` — заменён (логирование)
- `Backend/Desktop/src/lua_runtime.rs` — заменён (логирование init)

### 2. Применить патч к api.rs

Из `api.rs.patch.md` — добавить логи в `configs_create`, `configs_parse`,
`body_to_item`.

### 3. Пересобрать и запустить

```bash
cd Backend/Desktop
cargo build --release

Скопировать `target/release/lalune-backend.exe` в `%APPDATA%\.la-lune\LaLuneManager.exe`:

```
Get-Process LaLuneManager -ErrorAction SilentlyContinue | Stop-Process -Force
Copy-Item Backend\Desktop\target\release\lalune-backend.exe `
  "$env:APPDATA\.la-lune\LaLuneManager.exe" -Force
& "$env:APPDATA\.la-lune\LaLuneManager.exe"
```

### 4. Воспроизвести проблему

```
$link = "csqtt://e3HYC3JFPkRUTOq0GUzKR9kroW..."
Invoke-RestMethod -Uri "http://127.0.0.1:1062/configs" `
  -Method POST `
  -ContentType "application/json" `
  -Body (@{ link = $link; protocol = "CSQTT" } | ConvertTo-Json)
```

### 5. Посмотреть логи

**В stderr консоли** — там, где запущен `LaLuneManager.exe`, увидишь
все `[PARSE]`, `[CSQTT-LINK]`, `[LUA]`, `[API]`, `[CONFIG]` строки
в реальном времени.

**Через API:**

```
Invoke-RestMethod "http://127.0.0.1:1062/logs/tail?lines=200" | ConvertTo-Json -Depth 3
```

**Через браузер:**

```
http://127.0.0.1:1062/logs/tail?lines=200
```

## Что искать в логах

После `POST /configs` с encoded-ссылкой (`csqtt://<base64blob>`):

### Хороший сценарий (csqtt-link сработал)

```
[API] POST /configs protocol="CSQTT" link_len=350
[API] body_to_item: has link, calling parse_link
[PARSE] scheme-detect link=csqtt://e3HYC3JFPkRUTOq0GUzKR9kroW...RCr (len=350)
[PARSE][CSQTT] === start ===
[PARSE][CSQTT] raw link = csqtt://e3HYC3JF...RCr (len=350)
[PARSE][CSQTT] trying csqtt-link (AES-256-GCM)...
[CSQTT-LINK] parse called, input_len=350 starts_with_csqtt=true
[CSQTT-LINK] OK: host=1.2.3.4 port=46000 password_len=8 hashes=3 token_len=0
[PARSE][CSQTT] csqtt-link OK: host=1.2.3.4 port=46000 password_len=8 hashes=3
[PARSE][CSQTT] === success via csqtt-link ===
[API] /configs parsed: protocol=CSQTT peer=1.2.3.4:46000 ...
[CONFIG] insert: protocol=CSQTT peer=1.2.3.4:46000 ...
[CONFIG] inserted id=1234567
[API] /configs INSERTED id=1234567
```

### Если csqtt-link не смог

```
[PARSE][CSQTT] trying csqtt-link (AES-256-GCM)...
[CSQTT-LINK] parse called, input_len=350 starts_with_csqtt=true
[CSQTT-LINK] FAILED: decryption failed: authentication tag mismatch
[PARSE][CSQTT] csqtt-link FAILED: csqtt-link: decryption failed: authentication tag mismatch
[PARSE][CSQTT] trying Lua (csqtt_decode.lua)...
[LUA] decode_csqtt_link: input_len=350
[LUA] decode_csqtt_link: parse_csqtt_link error: runtime error: ...
[PARSE][CSQTT] Lua FAILED: csqtt_decode error: ...
[PARSE][CSQTT] trying native fallback (plain v=2 / user:pass@host)...
[PARSE][CSQTT] native fallback FAILED: csqtt:// not connect? and not user:pass@host — got 342 chars
[PARSE][CSQTT] === all parsers failed ===
[API] body_to_item: parse_link FAILED: csqtt:// invalid format (...)
```

По этой цепочке сразу видно:

- `decryption failed: authentication tag mismatch` → ключ (`"csqtt-chiper-key"`) неверный или IV не 12 байт.
- `csqtt_decode error: attempt to index a nil value (global 'bit32')` → Lua 5.4 в `mlua` + скрипт под 5.2 (нужен `bit32` шим).
- `csqtt:// not connect? and not user:pass@host` → нативный парсер увидел голый blob.

## Если вообще ничего не логируется

Значит ты запускаешь **старый** `LaLuneManager.exe`. Проверь:

```
Get-Item "$env:APPDATA\.la-lune\LaLuneManager.exe" | Select-Object LastWriteTime, Length
```

`LastWriteTime` должен быть **после** `cargo build --release`. Если старее —
значит копирование не сработало, или ты запустил старый процесс.

