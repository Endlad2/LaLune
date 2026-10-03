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

</BDS:create_file>

<BDS:create_file fileName="LaLune/BUILD.md">

```markdown
# Сборка LaLune

Единый скрипт `build.py` в корне проекта собирает и упаковывает Desktop.
Android / iOS / OpenWRT собираются отдельно (см. ниже).

## Оглавление

- [Desktop (Windows / Linux)](#desktop-windows--linux)
- [Android](#android)
- [iOS](#ios)
- [OpenWRT backend](#openwrt-backend)
- [Token Fetcher](#token-fetcher)
- [Требования](#требования)
- [CI](#ci)

---

## Desktop (Windows / Linux)

### Интерактивный режим

```bash
python build.py

Скрипт спросит платформу:

```
============================================
   LaLune build
============================================

  Под какую платформу собрать?

    1) Windows
    2) Linux

  Выбор [1/2]:
```

### CI-режим

```
python build.py --ci --target windows
python build.py --ci --target linux
```

### Что делает `build.py`

1. **Backend** — `cargo build --release` в `Backend/Desktop/`.
2. **Installer** (только Windows) — `cargo build --release` в `Installer/launcher/`.
3. **Копирует `Assets/` → `Frontend/assets/`** — Flutter не умеет брать
ассеты снаружи проекта.
4. **Frontend** — `flutter build windows --release` или
`flutter build linux --release`.
5. **Переименовывает бинарник** `lalune` / `lalune.exe` →
`LaLune` / `LaLune.exe` (как ждут installer'ы).
6. **Пакует в `Output/`**:

| Файл ↕▾ | Что внутри ↕▾ |
|---|---|
| −`LaLune-Windows.zip` | весь `Frontend/build/windows/x64/runner/Release/` |
| −`Backend-Windows.zip` | `LaLuneManager.exe` |
| −`Installer-Windows.zip` | `LaLune-Installer.exe` |
| −`LaLune-Linux.zip` | весь `Frontend/build/linux/x64/release/bundle/` |
| −`Backend-Linux.zip` | `LaLuneManager` |
⚙
7. **Чистит** (если не `--no-clean`):

- `flutter clean` в `Frontend/`
- `cargo clean` в `Backend/Desktop/`
- `cargo clean` в `Installer/launcher/` (если собирали)
- удаляет временную `Frontend/assets/`

### Формат вывода

```
[RUNNING] cargo build --release (Backend/Desktop)
[OK] cargo build --release (Backend/Desktop)  (42.3s)
[INFO] backend binary: /path/Backend/Desktop/target/release/lalune-backend
[RUNNING] flutter build windows --release
[OK] flutter build windows --release  (89.4s)

[INFO] packaging…
[OK] LaLune-Windows.zip  (12345 KB)
[OK] Backend-Windows.zip  (2345 KB)
[OK] Installer-Windows.zip  (3456 KB)

[OK] build complete: /path/Output

[INFO] cleaning build artifacts…
[OK] done.
```

### Флаги

| Флаг ↕▾ | Описание ↕▾ |
|---|---|
| −`--ci` | CI-режим, без вопросов, требует `--target` |
| −`--target {windows,linux}` | целевая платформа |
| −`--no-clean` | не чистить build-артефакты после сборки |
⚙

### Запуск собранного

**Windows:**

```
Output\LaLune-Windows.zip → распаковать → LaLune.exe
```

Требует `LaLuneManager.exe` рядом (`%APPDATA%\.la-lune\LaLuneManager.exe`)
— это делает `Installer/install.ps1`.

**Linux:**

```
cd Output
unzip LaLune-Linux.zip -d lalune
cd lalune
./LaLune
```

Требует `LaLuneManager` в `~/.la-lune/`.

---

## Android

### Требования

- Flutter 3.29+
- Android SDK + NDK 27
- Java 17

### Сборка

```
# 1. Копируем backend в android-проект
DST="Frontend/android/app/src/main/kotlin/com/lalune/lalune"
mkdir -p "$DST"
cp Backend/Android/*.kt "$DST/"

# 2. Копируем assets
rm -rf Frontend/assets
cp -r Assets Frontend/assets

# 3. Качаем ядра в jniLibs
mkdir -p Frontend/android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}
curl -L --fail -o Frontend/android/app/src/main/jniLibs/arm64-v8a/libclient-android-arm64-v8a.so \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-arm64-v8a.so
curl -L --fail -o Frontend/android/app/src/main/jniLibs/armeabi-v7a/libclient-android-armeabi-v7a.so \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-armeabi-v7a.so
curl -L --fail -o Frontend/android/app/src/main/jniLibs/x86_64/libclient-android-x86_64.so \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/libclient-android-x86_64.so

# 4. Собираем APK
cd Frontend
flutter pub get
flutter build apk --release      # или --debug
```

APK: `Frontend/build/app/outputs/flutter-apk/app-release.apk`.

### Структура Android-проекта

```
Frontend/android/app/src/main/
├── kotlin/com/lalune/lalune/
│   ├── MainActivity.kt
│   ├── Backend.kt
│   ├── CoreManager.kt
│   ├── LaLuneVpnService.kt
│   └── VkWebViewFetcher.kt
├── jniLibs/
│   ├── arm64-v8a/libclient-android-arm64-v8a.so
│   ├── armeabi-v7a/libclient-android-armeabi-v7a.so
│   └── x86_64/libclient-android-x86_64.so
└── AndroidManifest.xml
```

---

## iOS

### Требования

- macOS + Xcode 15+
- XcodeGen
- iOS 17.0+ deployment target

### Сборка

```
cd Frontend/ios

# Генерируем .xcodeproj из project.yml
xcodegen generate

# Собираем unsigned IPA
xcodebuild \
  -project Runner.xcodeproj \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Установка — через AltStore / Scarlet / Sideloadly.

### Что нужно

- App Group `group.com.lalune` (в Xcode → Signing & Capabilities).
- Entitlement NetworkExtension для tunnel-target `LaLuneTunnel`.
- `Backend.shared.run()` в `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.

---

## OpenWRT backend

### Требования

- Linux (SDK — x86_64)
- `curl`, `tar`, `zstd`
- Rust 1.75+

### Сборка через OpenWRT SDK

```
cd Backend/OpenWRT
./build.sh
```

Скрипт:

1. Скачивает `openwrt-sdk-25.12.5-armsr-armv8_gcc-14.3.0_musl.Linux-x86_64.tar.zst`
с `downloads.openwrt.org`.
2. Проверяет SHA256
(`1b0316604a3e820b2b008a1baff3f9dac6716af942bef800930e58c7de98c98b`).
3. Распаковывает в `.cache/openwrt-sdk/`.
4. Настраивает toolchain.
5. Собирает под `aarch64-unknown-linux-musl`.
6. Кладёт результат в `Backend/OpenWRT/output/lalune-openwrt-backend`.

### Установка на роутер

```
# С роутера одной строкой
wget -O - https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

Или:

```
scp Backend/OpenWRT/output/lalune-openwrt-backend root@192.168.1.1:/tmp/
ssh root@192.168.1.1
mkdir -p ~/.la-lune
mv /tmp/lalune-openwrt-backend ~/.la-lune/
chmod +x ~/.la-lune/lalune-openwrt-backend
~/.la-lune/lalune-openwrt-backend &
```

Backend слушает `0.0.0.0:1062`, виден из UI через
«Настройки → Экспериментальное → Роутеры → Подключить OpenWRT».

---

## Token Fetcher

### Требования

- .NET 8 SDK

### Сборка

```
python build_token_grabber.py --platform Windows
python build_token_grabber.py --platform Linux
```

Результат: `Core/LaLuneTokenFetcher/output/LaLuneTokenFetcher/`.

Chromium устанавливается в рантайме через `playwright install chromium`.

---

## Требования

### Общие

- Python 3.10+
- Flutter 3.29+
- Rust 1.75+

### Windows

- Visual Studio 2022 с workload **Native Desktop C++**
- Windows 10 / 11 SDK

### Linux

```
sudo apt-get install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev \
  libsqlite3-dev
```

### Android

- Android SDK (cmdline-tools, platform-tools)
- NDK 27.0.12077973
- Java 17

---

## CI

GitHub Actions workflow `.github/workflows/build.yml`:

| Job ↕▾ | Платформа ↕▾ | Что собирает ↕▾ |
|---|---|---|
| −`build-desktop-linux` | ubuntu-22.04 | `python build.py --ci --target linux` |
| −`build-desktop-windows` | windows-latest | `python build.py --ci --target windows` |
| −`build-desktop-openwrt` | ubuntu-22.04 | `Backend/OpenWRT/build.sh` |
| −`build-android` | ubuntu-latest | `flutter build apk --debug` |
| −`build-token-fetcher` | matrix (win/linux) | `build_token_grabber.py` |
| −`create-release` | ubuntu-latest | Сбор артефактов → GitHub Release |
⚙

Триггеры: push в `main` / `release`, ручной запуск (`workflow_dispatch`).

</BDS:create_file>

<BDS:create_file fileName="LaLune/INSTALL.md">

```markdown
# Установка LaLune

Короткие однокомандники для всех платформ.

---

## Windows

### Одной командой (PowerShell)

```powershell
irm https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/install.ps1 | iex

Или скачай `LaLune-Installer.exe` из
[последнего релиза](https://github.com/Endlad2/LaLune/releases/latest)
и запусти.

### Что делает

1. Создаёт `%APPDATA%\.la-lune\`.
2. Скачивает и распаковывает:

- `LaLune-Windows.zip` → `%APPDATA%\.la-lune\app\`
- `Backend-Windows.zip` → `%APPDATA%\.la-lune\`
- `client-windows-x86_64.exe` → `%APPDATA%\.la-lune\`
- `LATEST` → `%APPDATA%\.la-lune\`
- `icon.ico` → `%APPDATA%\.la-lune\`
- `wintun.dll` из `wintun-0.14.1.zip` → `%APPDATA%\.la-lune\`
3. Создаёт ярлыки:

- на рабочем столе
- в меню Пуск
4. Чистит временные файлы.

### Запуск

Ярлык **LaLune** на рабочем столе, или
`%APPDATA%\.la-lune\app\LaLune.exe`.

### Удаление

```
Remove-Item -Recurse -Force "$env:APPDATA\.la-lune"
Remove-Item "$env:USERPROFILE\Desktop\LaLune.lnk"
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\LaLune.lnk"
```

---

## Linux

### Одной командой

```
curl -fsSL https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/install.sh | bash
```

### Что делает

1. Определяет архитектуру (`x86_64` / `i686` / `aarch64` / `armv7`).
2. Создаёт `~/.la-lune/`.
3. Скачивает:

- `LaLune-Linux.zip` → распаковывает в `~/.la-lune/app/`
- `Backend-Linux.zip` → распаковывает в `~/.la-lune/`
- `client-linux-<arch>` → `~/.la-lune/`
- `LATEST` → `~/.la-lune/`
- `icon.ico` → `~/.la-lune/`
4. Создаёт:

- `~/.local/share/applications/lalune.desktop`
- симлинк `~/.local/bin/lalune` → `~/.la-lune/app/LaLune`
5. Чистит временные файлы.

### Запуск

Из меню приложений (иконка **LaLune**), или:

```
lalune                    # если ~/.local/bin в PATH
~/.la-lune/app/LaLune     # напрямую
```

Если команда `lalune` не найдена:

```
export PATH="$HOME/.local/bin:$PATH"
```

Добавь в `~/.bashrc` / `~/.zshrc`, чтобы сохранилось.

### Удаление

```
rm -rf ~/.la-lune
rm -f ~/.local/share/applications/lalune.desktop
rm -f ~/.local/bin/lalune
```

---

## OpenWRT (роутер, aarch64)

### Одной командой (на роутере)

```
wget -O - https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

Или через `curl`:

```
curl -fsSL https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

### Что делает

1. Создаёт `~/.la-lune/`.
2. Скачивает:

- `csqtt-client-aarch64` → `~/.la-lune/csqtt-client-aarch64`
- `lalune-openwrt-backend` → `~/.la-lune/lalune-openwrt-backend`
3. `chmod +x` на оба.
4. Убивает старый backend (если был).
5. Запускает `lalune-openwrt-backend` в фоне через `setsid nohup`
(или `nohup`).
6. Пишет PID в `~/.la-lune/backend.pid`, лог в
`~/.la-lune/LaLuneManager.log`.

Backend слушает `0.0.0.0:1062` — доступен по LAN.

### Проверка

На роутере:

```
curl http://127.0.0.1:1062/ping
```

С любого устройства в сети:

```
curl http://192.168.1.1:1062/ping
```

### Флаги `openwrt.sh`

```
sh openwrt.sh              # установить и запустить
sh openwrt.sh --force      # перекачать бинарники
sh openwrt.sh --stop       # остановить backend
sh openwrt.sh --status     # показать статус
```

### Подключение из UI

1. Открой LaLune на телефоне / десктопе (в той же Wi-Fi-сети).
2. **Настройки → Экспериментальное → Роутеры → Подключить OpenWRT**.
3. Найди роутер в списке (или введи IP вручную).
4. Нажми на роутер → **Установить соединение?**

Сверху появится зелёный баннер «Подключено к роутеру». Все API-запросы
уйдут на роутер. VK-токен передастся автоматически.

Отключение: клик по баннеру или **Настройки → Экспериментальное → Роутеры → Отключить**.
Процессы на роутере **не убиваются** — продолжают работать.

### Автозапуск при загрузке роутера

Добавь в `/etc/rc.local` перед `exit 0`:

```
[ -x "$HOME/.la-lune/lalune-openwrt-backend" ] && \
    nohup "$HOME/.la-lune/lalune-openwrt-backend" >>"$HOME/.la-lune/LaLuneManager.log" 2>&1 &
```

Или см. `Installer/README-OPENWRT.md` (init.d-скрипт).

### Удаление

```
sh openwrt.sh --stop
rm -rf ~/.la-lune
```

---

## Android

1. Скачай `LaLune-Android.apk` из
[последнего релиза](https://github.com/Endlad2/LaLune/releases/latest).
2. Разреши установку из неизвестных источников (Настройки → Безопасность).
3. Открой APK и установи.

Требуется Android 8.0+.

При первом запуске приложение запросит разрешение на VPN — разреши.

---

## iOS

1. Скачай `.ipa` из
[последнего релиза](https://github.com/Endlad2/LaLune/releases/latest).
2. Установи через AltStore / Scarlet / Sideloadly.
3. Доверься сертификату (Настройки → Основные → VPN и управление устройством).

Требуется iOS 17.0+.

---

## Общие требования

| Платформа ↕▾ | Что нужно ↕▾ |
|---|---|
| −Windows | Windows 10+, права администратора (для TUN) |
| −Linux | `sudo` для `ip route` и `/etc/resolv.conf` |
| −OpenWRT | aarch64 (armsr/armv8), `wget`/`curl`, root |
| −Android | Android 8.0+, разрешение VPN |
| −iOS | iOS 17.0+, NetworkExtension entitlement |
⚙

