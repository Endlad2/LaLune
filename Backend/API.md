# LaLune API — `http://127.0.0.1:1062`

Единый HTTP-интерфейс для всех бэкендов. Поддерживается **два протокола**:
CSQTT и PaperFlux. Протокол задаётся полем `protocol` в ConfigItem.

---

## Протоколы

### `GET /core/protocols`

```

[
{"id":"CSQTT","displayName":"CSQTT (VK Calls)","repo":"Endlad2/csqtt-core",...,"coreAsset":"client-windows-x86_64.exe"},
{"id":"PaperFlux","displayName":"PaperFlux (Docs)","repo":"Endlad2/PaperFlux-core",...,"coreAsset":"paperflux-windows-amd64.exe"}
]

```

### Core-эндпоинты per-protocol

| Метод | Путь | Описание |
|---|---|---|
| `GET` | `/core/{proto}/version` | локальная версия ядра |
| `GET` | `/core/{proto}/latest` | серверная версия |
| `GET` | `/core/{proto}/check` | `{hasUpdate,local,remote}` |
| `POST` | `/core/{proto}/download` | async-скачивание |
| `POST` | `/core/{proto}/download/sync` | sync-скачивание |
| `GET` | `/core/{proto}/path` | путь к бинарнику |
| `DELETE` | `/core/{proto}` | удалить ядро |

`{proto}` = `CSQTT` или `PaperFlux`.

Старые `/core/*` без proto — алиасы для CSQTT.

---

## Конфиги

### Формат ссылок

**CSQTT:**
```

csqtt://connect?v=2&host=...&peer=...&password=...&hashes=h1+h2+h3

```

**PaperFlux:**
```

paperflux://config?v=1&id=476&name=AccarFlux&server=31.76.252.123&ip=10.10.10.85&transport=yandex&doc=https%3A%2F%2Fdisk.yandex.ru%2Fi%2F...&token=...&volga=https%3A%2F%2Fdisk.yandex.ru%2Fi%2F...

```

Поля PaperFlux:
- `id` → `profileId`
- `name` → `name`
- `server` → `server`
- `ip` → `clientIp`
- `transport` → `transport` (yandex/vyandex/boards/mtslink/cupsonline/mailru/oneme/relayv2/direct)
- `doc` (или `url`) → `url`
- `urls` → `urls`
- `token` → `profileToken`
- `volga` → `volgaUrl`

### ConfigItem

```json
{
  "id": 1,
  "protocol": "CSQTT" | "PaperFlux",
  "name": "...",
  "peer": "...",           // CSQTT peer / PaperFlux server
  "password": "...",       // CSQTT
  "hashes": "...",         // CSQTT
  "profileId": "...",      // PaperFlux
  "profileToken": "...",   // PaperFlux
  "clientIp": "...",       // PaperFlux
  "transport": "...",      // PaperFlux
  "url": "...",            // PaperFlux
  "urls": "...",           // PaperFlux
  "volgaUrl": "...",       // PaperFlux
  "relayUrl": "...",       // PaperFlux
  "relayToken": "...",     // PaperFlux
  "maxToken": "...",       // PaperFlux
  "maxUid": "...",         // PaperFlux
  "server": "...",         // PaperFlux
  "rawLink": "..."
}
```

---

## Настройки

| Ключ ↕▾ | Протокол ↕▾ | Описание ↕▾ |
|---|---|---|
| −`peer`, `password`, `vkHashes` | CSQTT |  |
| −`workers`, `autoApiWorkers` | оба |  |
| −`obfs`, `fingerprint`, `clientIds` | CSQTT |  |
| −`authMode`, `turnTransport`, `captchaMode`, `vkAuthMode` | CSQTT |  |
| −`allowHashRedistribution`, `validateVkHashes` | CSQTT |  |
| −`pfTransport` | PaperFlux | yandex/vyandex/boards/mtslink/cupsonline/mailru/oneme/relayv2/direct |
| −`pfUrl`, `pfUrls`, `pfVolgaUrl` | PaperFlux | документные URL |
| −`pfMode` | PaperFlux | proxy/raw |
| −`pfSocks5` | PaperFlux | 127.0.0.1:1080 |
| −`pfTcpRecovery` | PaperFlux | auto/classic/rack |
| −`pfSession` | PaperFlux | bool |
| −`pfClientIp` | PaperFlux | 10.10.10.2 |
| −`pfAuthService`, `pfIpcSocket`, `pfTunFdSock`, `pfPacketSock` | PaperFlux |  |
| −`pfExitProfiles`, `pfExitStats`, `pfExitCookies` | PaperFlux |  |
| −`pfRelayUrl`, `pfRelayToken`, `pfRelayUser`, `pfRelaySession` | PaperFlux | relayv2 |
| −`pfMaxToken`, `pfMaxUid` | PaperFlux | MAX/OneMe |
| −`shareVpn`, `showCoreLogs`, `enableSmartTunnel` | оба |  |
⚙

### `GET /settings-for/{proto}`

Возвращает список ключей настроек, релевантных протоколу, и placeholder
для ссылки:

```
{
  "protocol": "PaperFlux",
  "keys": ["pfTransport", "pfUrl", ...],
  "linkPlaceholder": "paperflux://config?v=1&id=...&name=...&server=...&ip=...&transport=...&doc=...&token=...&volga=..."
}
```

---

## VPN

| Метод ↕▾ | Тело / Ответ ↕▾ |
|---|---|
| −`POST /vpn/connect` | `{configId:42}` → `{ok:true,status:"connecting"}` |
| −`POST /vpn/disconnect` | → `{ok:true}` |
| −`GET /vpn/status` | `{state,connected,uptimeSec,configId,message,since}` |
| −`GET /vpn/stats` | `{rxBytes,txBytes,rxRate,txRate,activeSessions}` |
⚙

**PaperFlux** всегда запускается в режиме `--client --mode proxy`
с SOCKS5 на `127.0.0.1:1080`. TUN-мост поднимается вокруг SOCKS5.

**CSQTT** запускается как раньше (напрямую в TUN).

---

## VK (только для CSQTT)

Стандартные эндпоинты — см. предыдущие версии.

---

## Логи

`?source=backend|core|all` — фильтр по источнику.

---

## Полный список

См. секции выше. Все остальные эндпоинты (`/vk/calls/*`, `/smarttunnel/*`,
`/deploy/*`, `/platform/*`, `/debug/*`, `/logs/*`, `/device/*`) сохранены
без изменений.

</BDS:create_file>

<BDS:create_file fileName="README-PaperFlux.md">

```markdown
# PaperFlux в LaLune

PaperFlux — второй поддерживаемый протокол после CSQTT. Пробрасывает
трафик через облачные документы (Yandex, Mail.ru, OneMe, Boards и др.).

## Ключевые отличия

| | CSQTT | PaperFlux |
|---|---|---|
| Транспорт | VK Calls + TURN | Documents (Yandex и др.) |
| Режим ядра | TUN напрямую | `--client --mode proxy` → SOCKS5 → TUN |
| VK-токен | нужен | не нужен |
| Ссылка | `csqtt://connect?...` | `paperflux://config?...` |
| Идентичность | `peer`/`password`/`hashes` | `profileId`/`profileToken` |

## Формат ссылки

paperflux://config?v=1&id=476&name=AccarFlux&server=31.76.252.123&ip=10.10.10.85&transport=yandex&doc=https%3A%2F%2Fdisk.yandex.ru%2Fi%2F...&token=...&volga=https%3A%2F%2Fdisk.yandex.ru%2Fi%2F...

```

Поля:
- `id` → `profileId`
- `name` → имя профиля (отображается в UI)
- `server` → адрес сервера
- `ip` → виртуальный IPv4 клиента (обычно `10.10.10.85`)
- `transport` → `yandex | vyandex | boards | mtslink | cupsonline | mailru | oneme | relayv2 | direct`
- `doc` или `url` → ссылка на документ
- `urls` → 1-2 ссылки через запятую
- `token` → secret профиля (≥32 символов)
- `volga` → отдельный пустой документ для Volga fallback

## Аргументы ядра

Всегда `--client`. Остальное:

### Режим и версия
- `--exit-node` — запуск как VPS exit (не используется в клиенте)
- `--client` — **всегда true**
- `--version`
- `--debug`

### Идентичность
- `--profile-id`
- `--profile-token`
- `--client-ip` (по умолчанию `10.10.10.2`)

### Транспорт
- `--transport` (yandex по умолчанию)
- `--session` (шифрованная сессия)
- `--tcp-recovery` (auto/classic/rack)

### Документы и URL
- `--url`
- `--urls`
- `--volga-url`

### Сеть
- `--mode proxy` — **всегда для LaLune**
- `--socks5 127.0.0.1:1080` — **всегда**
- `--auth-service`, `--ipc-socket`, `--tun-fd-sock`, `--packet-sock`

### Групповой exit
- `--exit-profiles`, `--exit-stats`, `--exit-cookies`

### Relay V2
- `--relay-url`, `--relay-token`, `--relay-user`, `--relay-session`

### MAX/OneMe
- `--maxToken`, `--maxUid`

## Где скачивается ядро

| Платформа | URL |
|---|---|
| Windows | `github.com/Endlad2/PaperFlux-core/releases/latest/download/paperflux-windows-amd64.exe` |
| Linux | `github.com/Endlad2/PaperFlux-core/releases/latest/download/paperflux-linux-amd64` |
| iOS | `github.com/Endlad2/PaperFlux-core/releases/latest/download/paperflux-ios.zip` (`liboflux.a` + `liboflux.h`) |
| Android | `github.com/Endlad2/PaperFlux-core/releases/latest/download/paperflux-android.zip` (`<abi>/libopenflux.so`) |

## Android

Ядро кладётся в `jniLibs/<abi>/libopenflux.so` и запускается через
`Process.start` — как CSQTT. Поэтому на Android имя всегда `libopenflux.so`.

## iOS

Ядро (`liboflux.a`) линкуется в `LaLuneTunnel` extension статически.
Tunnel вызывает `paperflux_run(args)` из `liboflux.h`. SOCKS5-мост
и TUN-мост — нативно внутри ядра (режим proxy).

## Расположение файлов

| Файл | Назначение |
|---|---|
| `%APPDATA%\.la-lune\paperflux-core.exe` (Win) | ядро |
| `~/.la-lune/paperflux-core` (Linux) | ядро |
| `filesDir/la-lune/core/libopenflux.so` (Android) | ядро |
| `LATEST.PaperFlux` | серверная версия |
| `LATEST.Csqtt` | серверная версия CSQTT |
