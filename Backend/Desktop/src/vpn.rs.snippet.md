# Фикс vpn.rs для FreeTurn

В `Backend/Desktop/src/vpn.rs` в `vpn_connect` (api.rs, не vpn.rs) добавь
ветку для FreeTurn. Сейчас `state::core_path_for(&state.app_dir, "FreeTurn")`
возвращает `freeturn-core.exe`, но в `core_path_for` нет ветки FreeTurn —
`ProtocolKind::from_id` есть, `local_filename` есть, а `core_path_for`
падает на `unwrap_or(Csqtt)`.

## `state.rs::core_path_for`

```rust
pub fn core_path_for(app_dir: &PathBuf, protocol_id: &str) -> PathBuf {
    let kind = crate::protocol::ProtocolKind::from_id(protocol_id)
        .unwrap_or(crate::protocol::ProtocolKind::Csqtt);
    app_dir.join(kind.local_filename())
}
```

Уже правильно. `local_filename()` для FreeTurn = `freeturn-core.exe`.

## `api.rs::vpn_connect` — добавить FreeTurn

```
ProtocolKind::FreeTurn => {
    if let Err(e) = core_manager::download_freeturn(&client, &core_path, &state.events).await {
        return err(500, format!("download FreeTurn failed: {}", e));
    }
}
```

## TUN для FreeTurn

`vpn_connect` вызывает `vpn::start_tun(vpn.clone(), ip, dns, events)`.
`start_tun` в `vpn.rs` уже умеет мостить UDP на `CORE_LISTEN_PORT` (5399).
FreeTurn в relay-only слушает `-listen 127.0.0.1:<listen_port>`, где
`listen_port = CORE_LISTEN_PORT = 5399` (мы передаём его в `build_freeturn_args`).

Ничего менять в `vpn.rs` не надо.

</BDS:create_file>

<BDS:create_file fileName="PATCH-DESKTOP-FREETURN.md">

```markdown
# Desktop: FreeTurn «не может сохранить конфиг»

## Симптом

На Windows Desktop приложение вставляет
`freeturn://eyJ2IjoxLCJwcm92aWRlciI6InZrIiwicGVlciI6IjMxLjc3LjE0OC4yMDM6NTczNzMi...`
и получает ошибку сохранения.

## Причина

`Backend/Desktop/src/config.rs::parse_link` **не содержит ветку
`freeturn://`**. Вызов падает в `parse_generic` (или вообще
`unsupported scheme`), `POST /configs` возвращает `400`,
UI пишет «не удалось сохранить».

В `Backend/Android/Backend.kt` ветка есть (мы её добавили в
`parseFreeTurn`), а в Rust-парсере её не было.

## Что сделано

### 1. `config.rs` — добавлен `parse_freeturn`

- base64url(json) с fallback на URL_SAFE (на случай padding).
- Поля: `v, provider, peer, transport, mode, bond, obf, key, timing,
  n, spc, cid, listen, dns, dnss, mcap, name, vk, wg`.
- `ConfigItem` расширен полями `obf_profile, obf_key, mode, n, spc,
  client_id, dns_mode, dns_servers, vk_link, wg_conf, wg_relay`.
- `wg_relay = true`, если `Endpoint = 127.0.0.1:9000` (relay-топология).
- SQLite: миграция добавляет новые колонки `ALTER TABLE`.

### 2. `protocol.rs` — `build_freeturn_args`

Собирает argv для FreeTurn-клиента (relay-only):

freeturn-core.exe
-listen 127.0.0.1:5399
-peer 31.77.148.203:57373
-provider vk
-links <link>
-n 12  -streams-per-cred 12
-transport udp
-mode udp
-obf-profile rtpopus3
-obf-key 4af381...
-dns-mode auto
-client-id 25d1d6de0635e94f6c3e7afa9dd28eea
-platform desktop

```

Это ровно то, что делает `docs/quickstart.md` upstream, только без
`-routes` (Desktop-бэкенд сам настраивает маршруты).

`wg_conf` в argv не попадает: TUN поднимает `vpn.rs` (Wintun/Linux tun),
мост UDP 127.0.0.1:5399.

### 3. `core_manager.rs` — `download_freeturn`

Ассеты: `client-windows-amd64.exe` / `client-linux-amd64` / `client-linux-arm64`.
URL: `https://github.com/hackdiaz-dev/free-turn-proxy/releases/latest/download/<asset>`.

### 4. `api.rs` — не терять поля

`ConfigCreateBody` и `body_to_item` расширены новыми полями
(`obfProfile`, `obfKey`, `mode`, `n`, `spc`, `clientId`, `dnsMode`,
`dnsServers`, `vkLink`, `wgConf`, `wgRelay`).

## Проверка

```powershell
# backend запущен: & "$env:APPDATA\.la-lune\LaLuneManager.exe"

$link = 'freeturn://eyJ2IjoxLCJwcm92aWRlciI6InZrIiwicGVlciI6IjMxLjc3LjE0OC4yMDM6NTczNzMiLCJ0cmFuc3BvcnQiOiJ1ZHAiLCJvYmYiOiJydHBvcHVzMyIsImtleSI6IjRhZjM4MWUzMDM0MGJiNTcxNmY5NjE0ZmU1ZDFkMmI1NGY5NDM4N2I2Yjc5YTZjZDM4NGQwMDE0NzMyZGM5ZjQiLCJuIjoxMiwic3BjIjoxMiwiY2lkIjoiMjVkMWQ2ZGUwNjM1ZTk0ZjZjM2U3YWZhOWRkMjhlZWEiLCJuYW1lIjoiVXNlcnMiLCJ3ZyI6IltJbnRlcmZhY2VdXG5Qcml2YXRlS2V5ID0gU0hTYURHRDhnT0VWK0h2dXBIc3BrRmg3YTVPKys3czM2ZGFlZHJ1OGNuaz1cbkFkZHJlc3MgPSAxMC4xMy4xMy4zLzMyXG5ETlMgPSAxLjEuMS4xLCAxLjAuMC4xXG5bUGVlcl1cblB1YmxpY0tleSA9IGF5MmI1TDNFT2NjTWNJcTJSQkp1ZUpmSVM3Vi96NmM0NytoTlB2VFlUQ0E9XG5BbGxvd2VkSVBzID0gMC4wLjAuMC8wLCA6Oi8wXG5FbmRwb2ludCA9IDEyNy4wLjAuMTo5MDAwXG5QZXJzaXN0ZW50S2VlcGFsaXZlID0gMjUifQ'

# parse
Invoke-RestMethod -Uri "http://127.0.0.1:1062/configs/parse" `
  -Method POST -ContentType "application/json" `
  -Body (@{ link = $link } | ConvertTo-Json) | ConvertTo-Json -Depth 4

# ожидаем:
# {
#   "protocol": "FreeTurn",
#   "peer": "31.77.148.203:57373",
#   "name": "Users",
#   "obfProfile": "rtpopus3",
#   "obfKey": "4af381e30340bb5716f9614fe5d1d2b54f94387b6b79a6cd384d0014732dc9f4",
#   "mode": "udp",
#   "transport": "udp",
#   "n": 12,
#   "spc": 12,
#   "clientId": "25d1d6de0635e94f6c3e7afa9dd28eea",
#   "wgRelay": true,
#   "rawLink": "freeturn://..."
# }

# save
Invoke-RestMethod -Uri "http://127.0.0.1:1062/configs" `
  -Method POST -ContentType "application/json" `
  -Body (@{ link = $link } | ConvertTo-Json)
# → {"id": 1234567}
```

Если `missing 'peer'` — payload не расшифровался. Если `base64 decode` —
неверный base64url (padding/wrap).

## Отладка

```
# логи бэкенда
Get-Content "$env:APPDATA\.la-lune\LaLuneManager.log" -Tail 50
```

Ищи:

```
[PARSE][FREETURN] === start ===
[PARSE][FREETURN] raw link = freeturn://eyJ2IjoxLCJwcm92aWRlciI6InZr...
[PARSE][FREETURN] === success === peer=31.77.148.203:57373 name=Users ...
```

Если видишь `[PARSE] unsupported scheme` — старый `config.rs`, не
пересобран. Проверь `cargo build --release`.

## Что осталось

`Desktop/src/vpn.rs` уже мостит UDP на `CORE_LISTEN_PORT = 5399`.
`build_freeturn_args` передаёт `-listen 127.0.0.1:5399`. Всё согласовано.

FreeTurn не требует встроенного WireGuard на Desktop: TUN поднимает
`vpn::start_tun` (Wintun на Windows, `tun` crate на Linux). `wg_conf`
из `freeturn://` хранится в БД (`wg_conf`, `wg_relay`) для будущего,
но в argv не идёт.

