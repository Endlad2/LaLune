# GitHub Actions — LaLune

## Workflow'ы

| Файл ↕▾ | Что делает ↕▾ |
|---|---|
| −`build.yml` | Desktop (Windows + Linux), Android APK, Token Fetcher, Release |
| −`build-ios.yml` | iOS IPA (unsigned, для AltStore/Scarlet) |
⚙

## Триггеры

Оба workflow запускаются:

- при `push` в `main` / `release` (`build-ios` — ещё `master`)
- вручную через **Actions → Run workflow**
- `build-ios` дополнительно на теги `v*` (для аттача IPA к релизу)

## Как работает `build.yml`

### `build-desktop-linux`

```
ubuntu-22.04
├── python 3.12
├── rust stable
├── flutter 3.24.5
├── apt install gtk3-dev, clang, cmake, ninja, pkg-config
└── python build.py --ci --target linux
     ├── cargo build --release (Backend/Desktop)
     ├── flutter pub get
     ├── flutter build linux --release
     ├── rename lalune → LaLune
     ├── package LaLune-Linux.zip
     ├── package Backend-Linux.zip
     └── clean
```

Артефакт: `Output-Linux` (содержит `LaLune-Linux.zip`, `Backend-Linux.zip`).

### `build-desktop-windows`

```
windows-latest
├── python 3.12
├── rust stable
├── flutter 3.24.5
└── python build.py --ci --target windows
     ├── cargo build --release (Backend/Desktop)
     ├── cargo build --release (Installer/launcher)
     ├── flutter pub get
     ├── flutter build windows --release
     ├── rename lalune.exe → LaLune.exe
     ├── package LaLune-Windows.zip
     ├── package Backend-Windows.zip
     ├── package Installer-Windows.zip
     └── clean
```

Артефакт: `Output-Windows` (содержит 3 zip).

### `build-android`

```
ubuntu-latest
├── python 3.12
├── flutter 3.24.5
├── java 17
├── Android SDK (preinstalled)
├── copy Backend/Android/*.kt → Frontend/android/.../com/lalune/backend/
├── copy Assets/ → Frontend/assets/
├── copy Core/SmartTunnel.lua → Frontend/android/.../assets/
├── download libclient-android-*.so → jniLibs/
├── flutter pub get
├── flutter build apk --debug
└── cp app-debug.apk → Output/LaLune-Android.apk
```

Артефакт: `Output-Android` (`LaLune-Android.apk`).

### `build-token-fetcher`

**Без изменений** — matrix Windows + Linux, `dotnet publish` через
`build_token_grabber.py`, упаковка в `LaLuneTokenFetcher_<OS>.zip`.

### `create-release`

Запускается после всех. Собирает все zip'ы + APK в `release/` и создаёт
GitHub Release с тегом вида `26.10.03.15.30`.

Файлы в релизе:

- `LaLune-Windows.zip`
- `Backend-Windows.zip`
- `Installer-Windows.zip`
- `LaLune-Linux.zip`
- `Backend-Linux.zip`
- `LaLune-Android.apk`
- `LaLuneTokenFetcher_Windows.zip`
- `LaLuneTokenFetcher_Linux.zip`

## Как работает `build-ios.yml`

```
macos-14
├── Xcode 15.4
├── flutter stable
├── xcodegen
├── copy Backend/iOS/*.swift → Frontend/ios/Runner/ + Tunnel/
├── copy Assets/ → Frontend/assets/
├── flutter pub get
├── download libcsqtt_ios_core.a → Frontend/ios/Core/
├── xcodegen generate (Runner.xcodeproj)
├── patch objectVersion 77 → 56
├── xcodebuild archive (unsigned)
└── package Payload/ → LaLune.ipa
```

Артефакт: `LaLune-iOS-unsigned` (`LaLune.ipa`).

**Что нужно от тебя:**

- `Frontend/ios/project.yml` — конфиг XcodeGen с двумя target'ами:
`Runner` (основное приложение) + `Tunnel` (Network Extension).
- `Frontend/ios/Entitlements/Runner.entitlements` — App Groups + Network Extension.
- `Frontend/ios/Entitlements/Tunnel.entitlements` — packet-tunnel-provider.

Как только будут — workflow соберётся. Структура каталогов должна быть:

```
Frontend/ios/
├── project.yml
├── Entitlements/
│   ├── Runner.entitlements
│   └── Tunnel.entitlements
├── Runner/
│   ├── AppDelegate.swift        ← наш
│   ├── Backend.swift            ← копируется workflow'ом
│   ├── HttpServer.swift         ← копируется workflow'ом
│   ├── CoreManager.swift        ← копируется workflow'ом
│   ├── VkWebViewController.swift← копируется workflow'ом
│   ├── Info.plist               ← наш
│   └── Assets.xcassets/
├── Tunnel/
│   ├── PacketTunnelProvider.swift ← копируется workflow'ом
│   └── Info.plist
└── Core/
    └── libcsqtt_ios_core.a      ← скачивается workflow'ом
```

## Локальная проверка

Если хочешь понять, что workflow делает, просто прогони то же самое локально:

**Windows:**

```
python build.py --ci --target windows
```

**Linux:**

```
python build.py --ci --target linux
```

Оба требуют Flutter, Rust и Python в PATH.

## Отладка

Если job падает:

1. **Desktop** — проверь `flutter doctor -v` и `cargo --version` в логах. Часто Flutter не находит VS на Windows — тогда в `build.py` увидишь `[FAIL] flutter build windows`.
2. **Android** — проверь, что `Backend/Android/*.kt` скопировались в нужный package (`com.lalune.backend`). Если gradle не видит — смотри `app/build.gradle`, нужно `sourceSets` включать `.kt` из этого пакета.
3. **Token Fetcher** — оставлен без изменений, работает как раньше.
4. **iOS** — самый хрупкий. Порядок: Xcode → xcodegen → patch objectVersion → archive. Если `xcodegen generate` падает — проверь `project.yml`.