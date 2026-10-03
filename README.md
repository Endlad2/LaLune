# LaLune

<img src="https://count.owenewans.org/Endlad2/LaLune?theme=moebooru&notitle" alt="count" />

Кроссплатформенный VPN-клиент для протокола **CSQTT**. Единый Flutter UI,
платформенные бэкенды на Rust / Kotlin / Swift, поддержка десктопа,
мобильных устройств и OpenWRT-роутеров.

## Что это

LaLune — клиент для обхода блокировок на базе протокола
[CSQTT](https://github.com/Endlad2/csqtt-core). Трафик маскируется под
VK Calls, TURN используется для обхода NAT, WRAP — для шифрования,
обфускация скрывает сигнатуру.

## Платформы

| Платформа | Статус | Стек | Ядро |
|---|---|---|---|
| Windows | ✅ | Flutter + Rust (axum) + Wintun | `client-windows-x86_64.exe` |
| Linux | ✅ | Flutter + Rust (axum) + TUN | `client-linux-x86_64` |
| Android | ✅ | Flutter + Kotlin + VpnService | `libclient-android-*.so` |
| iOS 17+ | ✅ | Flutter + Swift + NetworkExtension | `csqtt-core` (static lib) |
| OpenWRT | ✅ | Rust (axum) + TUN | `csqtt-client-aarch64` |

## Быстрая установка

### Windows

```powershell
irm https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/install.ps1 | iex
```

Или скачай `LaLune-Installer.exe` из
[Releases](https://github.com/Endlad2/LaLune/releases) и запусти.

Что делает: создаёт `%APPDATA%\.la-lune\`, качает клиент, backend,
ядро CSQTT, wintun.dll, создаёт ярлыки на рабочем столе и в меню Пуск.

### Linux

```
curl -fsSL https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/install.sh | bash
```

Что делает: создаёт `~/.la-lune/`, качает клиент, backend, ядро,
иконку, создаёт `.desktop`-файл и симлинк `~/.local/bin/lalune`.

### OpenWRT (роутер, aarch64)

```
wget -O - https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

Что делает: кладёт ядро `csqtt-client-aarch64` и
`lalune-openwrt-backend` в `~/.la-lune/`, запускает backend в фоне
на `0.0.0.0:1062`. После этого роутер виден из UI через
«Настройки → Экспериментальное → Роутеры → Подключить OpenWRT».

### Android

Скачай `LaLune-Android.apk` из [Releases](https://github.com/Endlad2/LaLune/releases)
и установи. Требуется Android 8.0+.

### iOS

Скачай `.ipa` из [Releases](https://github.com/Endlad2/LaLune/releases) и
поставь через AltStore / Scarlet / Sideloadly.
Требуется iOS 17.0+.

## Архитектура

```
LaLune/
├── Backend/                 — платформенные HTTP-демоны
│   ├── Desktop/             — Rust (axum + tun) для Windows/Linux
│   ├── Android/             — Kotlin (ServerSocket + VpnService)
│   ├── iOS/                 — Swift (Network.framework + NETunnelProvider)
│   └── OpenWRT/             — Rust (axum + tun), bind 0.0.0.0:1062
├── Core/                    — вспомогательное
│   ├── DeployManager/       — SSH-деплой ядер (Rust)
│   ├── LaLuneTokenFetcher/  — Playwright-геттер VK-токена (.NET)
│   └── LaLuneTokenFetcherAndroid.java
├── Frontend/                — Flutter UI (общий для всех платформ)
│   └── lib/
│       ├── api/             — HTTP + SSE клиент к 127.0.0.1:1062
│       ├── pages/           — Подключение / Настройки / Инфо / Логи
│       ├── state/           — Riverpod-провайдеры + notifier'ы
│       └── widgets/         — Moon button, navbar, router modal
├── Installer/               — установщики
│   ├── install.ps1          — Windows
│   ├── install.sh           — Linux
│   └── openwrt.sh           — OpenWRT
├── OpenWRT/                 — standalone-клиент для роутера (без SDK)
├── Assets/                  — иконки, фоны, шрифты
├── build.py                 — единый сборщик Desktop
└── BUILD.md                 — подробности сборки
```

## Как это работает

1. **UI (Flutter)** общается с платформенным бэкендом по HTTP на
`127.0.0.1:1062`. Никакой платформенной специфики в UI нет — он
дёргает один и тот же REST + SSE.
2. **Бэкенд** (Rust / Kotlin / Swift) запускает ядро CSQTT, управляет
TUN-интерфейсом и UDP-мостом к ядру, хранит конфиги, настройки и
VK-токен.
3. **Ядро CSQTT** устанавливает соединение с VK Calls / TURN и
поднимает локальный UDP-listener на `127.0.0.1:52230`. Бэкенд
пробрасывает через него TUN-трафик.
4. **OpenWRT-режим**: если в UI подключиться к роутеру
(Настройки → Экспериментальное → Роутеры), все API-запросы уходят
на `<ip-роутера>:1062`. Наш VK-токен передаётся роутеру для
создания звонков. Ядро и бэкенд на роутере продолжают работать,
даже если UI отключится.

## Сборка из исходников

Требуется:

- **Rust 1.75+** (rustup.rs)
- **Flutter 3.29+** ([flutter.dev](https://docs.flutter.dev/get-started/install))
- **Python 3.10+**
- Для Windows: **Visual Studio 2022** (Native Desktop C++)
- Для Linux: `libgtk-3-dev liblzma-dev libstdc++-12-dev clang cmake ninja-build`

### Desktop (Windows / Linux)

```
python build.py                 # интерактивно: спросит платформу
python build.py --ci --target windows
python build.py --ci --target linux
```

Скрипт соберёт backend + frontend + (для Windows) installer, упакует в
`Output/*.zip` и сделает `flutter clean` / `cargo clean`.

Подробности — в [`BUILD.md`](https://build.md/).

### OpenWRT backend

Сборка через официальный OpenWRT SDK (armsr/armv8, musl):

```
cd Backend/OpenWRT
./build.sh
```

Скрипт скачает `openwrt-sdk-25.12.5-armsr-armv8_gcc-14.3.0_musl.Linux-x86_64`,
проверит SHA256, распакует в `.cache/openwrt-sdk/` и соберёт
`output/lalune-openwrt-backend` под `aarch64-unknown-linux-musl`.

### Android

```
cd Frontend
flutter pub get
flutter build apk --release
```

APK появится в `Frontend/build/app/outputs/flutter-apk/`.

### iOS

```
cd Frontend/ios
xcodegen generate
xcodebuild -project Runner.xcodeproj -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## Конфигурация

### Ссылка подключения

```
csqtt://connect?v=2&host=HOST&peer=PORT&password=PASSWORD&hashes=H1+H2+H3
```

### Файлы данных

Все платформы работают с одинаковой структурой в `<appDir>`:

| Файл ↕▾ | Назначение ↕▾ |
|---|---|
| −`settings.json` | настройки клиента |
| −`configs.json` / `configs.db` | список конфигов |
| −`token.json` | VK access_token |
| −`LATEST` | версия установленного ядра |
| −`logs.log` | логи ядра |
| −`client-*` / `libclient-*.so` | бинарник ядра |
⚙

Где искать `<appDir>`:

| ОС ↕▾ | Путь ↕▾ |
|---|---|
| −Windows | `%APPDATA%\.la-lune\` |
| −Linux | `~/.la-lune/` |
| −Android | `filesDir/la-lune/` |
| −iOS | `Documents/la-lune/` + App Group `group.com.lalune` |
| −OpenWRT | `~/.la-lune/` |
⚙

## API

Полное описание REST + SSE — в [`Backend/API.md`](https://backend/API.md).
Все платформы реализуют одинаковый контракт:

```
GET  /ping
GET  /version
GET  /events            (SSE)
POST /vpn/connect
GET  /vpn/status
GET  /configs
PUT  /settings
GET  /logs/tail?lines=100
POST /vk/token/login
GET  /vk/token/state
POST /vk/calls/start
...
```

## CI

GitHub Actions workflow `.github/workflows/build.yml` собирает:

| Job ↕▾ | Что делает ↕▾ |
|---|---|
| −`build-desktop-linux` | `python build.py --ci --target linux` |
| −`build-desktop-windows` | `python build.py --ci --target windows` |
| −`build-desktop-openwrt` | `Backend/OpenWRT/build.sh` через OpenWRT SDK |
| −`build-android` | `flutter build apk --debug` |
| −`build-token-fetcher` | `build_token_grabber.py` для Win/Linux |
| −`create-release` | Собирает артефакты и публикует Release |
⚙

Триггеры: push в `main` / `release`, `workflow_dispatch`.

## Лицензия

**PolyForm Noncommercial License 1.0.0**

Проект является строго некоммерческим исследовательским инструментом.
Любая продажа, перепродажа, интеграция в платные сервисы или извлечение
прибыли на базе данного кода запрещены.

Ядро CSQTT: [github.com/Endlad2/csqtt-core](https://github.com/Endlad2/csqtt-core)

## Авторы

- **LaLune** — [@Endlad7373](https://github.com/Endlad2)
- **CSQTT** — [@amurcanov](https://github.com/amurcanov)

