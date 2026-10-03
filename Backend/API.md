# LaLune API — `http://127.0.0.1:1062`

Единый HTTP-интерфейс для всех бэкендов (Desktop Rust, Android Kotlin,
iOS Swift, OpenWRT Rust). Все ответы — JSON. Ошибки:
`{ "error": "...", "code": 4xx|5xx }`.

---

## Базовые

### `GET /ping`

```

{ "ok": true, "version": "0.6.0", "os": "linux", "arch": "x86_64", "uptime": 1234 }

```

### `GET /version`

```

{ "api": 1, "backend": "0.6.0", "core": "2026.09.12", "ui": "0.6.0" }

```

### `GET /events` (SSE)

```

data: {"type":"log","line":"[INFO] ...","ts":1759331294}
data: {"type":"log","line":"[CORE] [СТАТИСТИКА] ...","ts":1759331294}
data: {"type":"status","connected":true,"ts":1759331294}
data: {"type":"progress","kind":"core_download","percent":42}
data: {"type":"progress","kind":"vk_token","percent":60,"message":"..."}
data: {"type":"event","name":"tun_ready","data":{"ip":"10.66.67.12","dns":"8.8.8.8"}}
data: {"type":"error","message":"..."}

```

### `POST /shutdown` → `{ "ok": true }`

---

## Конфиги

| Метод | Тело / Ответ |
|---|---|
| `GET /configs` | `[{"id":1,"protocol":"CSQTT","peer":"host:46000",...}]` |
| `GET /configs/{id}` | один конфиг или 404 |
| `POST /configs` | `{protocol, link}` или `{protocol, peer, password, hashes, name}` → `{id:42}` |
| `PUT /configs/{id}` | как POST → `{ok:true}` |
| `DELETE /configs/{id}` | → `{ok:true}` |
| `POST /configs/parse` | `{link:"csqtt://..."}` → распарсенный конфиг |
| `GET /configs/selected` | выбранный или `{}` |
| `PUT /configs/selected` | `{id:42}` или `{}` |

---

## Настройки

| Метод | Описание |
|---|---|
| `GET /settings` | все настройки |
| `PUT /settings` | заменить целиком |
| `PATCH /settings` | частично |
| `POST /settings/reset` | сброс к дефолтам |
| `GET /settings/{key}` | одна |
| `PUT /settings/{key}` | обновить одну |

### Схема настроек

```json
{
  "peer": "", "vkHashes": "", "vkJsToken": "",
  "workers": 9, "autoApiWorkers": 9,
  "password": "", "obfs": "video", "fingerprint": "firefox",
  "clientIds": "8202606,6287487", "deviceId": "...",
  "authMode": "manual", "turnTransport": "udp",
  "turnHost": "", "turnPort": "",
  "captchaMode": "auto", "vkAuthMode": "vkcalls",
  "allowHashRedistribution": false, "validateVkHashes": false,
  "enableSmartTunnel": false,
  "showCoreLogs": false
}
```

`showCoreLogs` — показывать ли в UI логи ядра (строки с префиксом `[CORE] `).
По умолчанию `false`.

---

## Device

| Метод ↕▾ | Ответ ↕▾ |
|---|---|
| −`GET /device/id` | `{ "deviceId": "abc..." }` |
| −`POST /device/id/regenerate` | `{ "deviceId": "new..." }` |
| −`GET /device/info` | `{os,arch,hostname,cores,totalMemMb}` |
⚙

---

## VPN

| Метод ↕▾ | Тело / Ответ ↕▾ |
|---|---|
| −`POST /vpn/connect` | `{configId:42}` или `{}` → `{ok:true,status:"connecting"}` |
| −`POST /vpn/disconnect` | → `{ok:true}` |
| −`GET /vpn/status` | `{state,connected,uptimeSec,configId,message,since}` |
| −`POST /vpn/reconnect` | → `{ok:true}` |
| −`GET /vpn/stats` | `{rxBytes,txBytes,rxRate,txRate,activeSessions}` |
| −`GET /vpn/tunconf` | `{ip,dns,mtu}` или `{}` |
⚙

---

## Логи

Все эндпоинты поддерживают query-параметр `?source=backend|core|all`
(по умолчанию `all`):

- `source=backend` — только строки бэкенда (без префикса `[CORE] `)
- `source=core` — только строки ядра CSQTT (начинаются с `[CORE] `)
- `source=all` — всё вместе

| Метод ↕▾ | Ответ ↕▾ |
|---|---|
| −`GET /logs?source=all` | `["line1","line2",...]` |
| −`GET /logs/tail?lines=100&source=backend` | последние N |
| −`DELETE /logs` | `{ok:true}` (очищает весь буфер) |
| −`GET /logs/stream` | SSE только логов |
| −`GET /logs/export?source=all` | `text/plain` файл |
⚙

---

## Ядро CSQTT

| Метод ↕▾ | Ответ ↕▾ |
|---|---|
| −`GET /core/version` | `{version:"2026.09.12"}` |
| −`GET /core/latest` | `{version:"2026.09.12"}` |
| −`GET /core/check` | `{hasUpdate:false,local:"...",remote:"..."}` |
| −`POST /core/download` | async, прогресс через SSE |
| −`POST /core/download/sync` | синхронно |
| −`DELETE /core` | `{ok:true}` |
| −`GET /core/path` | `{path:"/home/.../client-linux-x86_64"}` |
| −`GET /core/protocols` | `[{id,displayName,repo,realtime,description,coreAsset}]` |
⚙

---

## Обновление LaLune

| Метод ↕▾ | Ответ ↕▾ |
|---|---|
| −`GET /update/check` | `{hasUpdate,remoteTag,localVersion}` |
| −`GET /update/url` | `{url:"https://github.com/..."}` |
⚙

---

## VK

| Метод ↕▾ | Тело / Ответ ↕▾ |
|---|---|
| −`GET /vk/token/state` | `{hasToken,fetching,progress,message}` |
| −`POST /vk/token/login` | Desktop: запускает Token.ps1/Token.sh. Mobile: `{needsUi:true,authUrl:"https://oauth.vk.ru/..."}` |
| −`POST /vk/token/submit` | `{token:"vk1.a.xxx"}` → `{ok:true}` |
| −`GET /vk/token/raw` | `{token:"vk1.a.xxx"}` — сырой токен (для передачи на роутер) |
| −`DELETE /vk/token` | `{ok:true}` |
| −`GET /vk/token/validate` | `{valid:true,message:""}` |
| −`POST /vk/token/fetch/cancel` | `{ok:true}` |
⚙

---

## VK Auto Calls

| Метод ↕▾ | Тело / Ответ ↕▾ |
|---|---|
| −`POST /vk/calls/start` | `{workers:27,autoApiWorkers:9}` → `{hashes:[],callIds:[]}` |
| −`POST /vk/calls/stop` | `{callIds:[]}` → `{finished:N}` |
| −`POST /vk/calls/stop-all` | → `{finished:N}` |
| −`GET /vk/calls/active` | `{callIds:[]}` |
⚙

---

## SmartTunnel

| Метод ↕▾ | Ответ ↕▾ |
|---|---|
| −`GET /smarttunnel/status` | `{running:true}` |
| −`POST /smarttunnel/start` | `{ok:true}` |
| −`POST /smarttunnel/stop` | `{ok:true}` |
| −`POST /smarttunnel/reload` | `{ok:true}` |
| −`GET /smarttunnel/logs` | `["...", "..."]` |
| −`GET /smarttunnel/args` | `["--peer","..."]` |
| −`PUT /smarttunnel/args` | `["--peer","..."]` → `{ok:true}` |
⚙

---

## Deploy (заглушка)

| Метод ↕▾ | Ответ ↕▾ |
|---|---|
| −`POST /deploy/run` | `{stub:true}` |
| −`GET /deploy/status` | `{busy:false,stub:true}` |
| −`GET /deploy/log` | `{log:"",stub:true}` |
| −`POST /deploy/cancel` | `{stub:true}` |
| −`GET /deploy/protocols` | `{protocols:[],stub:true}` |
⚙

---

## Platform

| Метод ↕▾ | Тело / Ответ ↕▾ |
|---|---|
| −`GET /platform/capabilities` | `{canShowWebView,canRunTun,canDeploy,canAutoUpdate,canSendNotifications,canOpenExternalUrl,os,platform}` |
| −`POST /platform/open-url` | `{url}` → `{ok:true}` |
| −`POST /platform/notify` | `{title,body}` → `{ok:true}` |
| −`POST /platform/open-path` | `{path}` → `{ok:true}` |
| −`POST /platform/share` | `{text?,filePath?}` → `{ok:true}` |
⚙

---

## Debug

| Метод ↕▾ | Ответ ↕▾ |
|---|---|
| −`GET /debug/state` | полный снапшот |
| −`POST /debug/echo` | эхо тела запроса |
| −`GET /debug/config` | `{appDir,configsPath,settingsPath,logsPath,tokenPath,corePath}` |
| −`POST /debug/reload-config` | `{ok:true}` |
⚙

