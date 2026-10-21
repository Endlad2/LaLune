# Патч Core/csqtt-link/src/lib.rs для Android (JNI)

Чтобы `libcsqtt_decode.so` экспортировал JNI-функции
`Java_com_lalune_lalune_CsqttLink_nativeParse` и т.д., нужно:

## 1. В `Core/csqtt-link/Cargo.toml` добавить

```toml
[target.'cfg(target_os = "android")'.dependencies]
jni = "0.21"
```

## 2. В конец `Core/csqtt-link/src/lib.rs` добавить

```
#[cfg(target_os = "android")]
mod jni_wrapper;
```

## 3. Положить `Backend/Android/jni_wrapper.rs` в `Core/csqtt-link/src/jni_wrapper.rs`

Файл уже в этом zip как `Backend/Android/jni_wrapper.rs` — скопировать в
`Core/csqtt-link/src/jni_wrapper.rs`.

## 4. Проверить сборку

```
cd Core/csqtt-link
cargo ndk --target aarch64-linux-android --platform 24 \
  -o ../../Frontend/android/app/src/main/jniLibs build --release
```

В `jniLibs/arm64-v8a/` появится `libcsqtt_decode.so`, в котором
экспортированы три JNI-символа. `CsqttLink.kt` их вызовет через
`nativeParse`, `nativeDecode`, `nativeLastError`.

</BDS:create_file>

<BDS:create_file fileName="PATCH-ALL.md">

```markdown
# Итоговый патч — всё что «руками»

В этом zip — все файлы, которые нужно вручную применить к репозиторию
после предыдущих патчей (Lua + csqtt-link).

## Что внутри

### Backend/Desktop

| Файл | Что изменено |
|---|---|
| `Cargo.toml` | добавлен `csqtt-link = { path = "../../Core/csqtt-link" }` |
| `src/main.rs` | `mod csqtt_link_bridge;` |
| `src/csqtt_link_bridge.rs` | новый: обёртка `parse()` над крейтом |
| `src/config.rs` | `parse_csqtt()` — приоритет csqtt-link → Lua → нативный |

### Backend/OpenWRT

| Файл | Что изменено |
|---|---|
| `Cargo.toml` | добавлен `csqtt-link = { path = "../../Core/csqtt-link" }` |
| `src/main.rs` | `mod csqtt_link_bridge;` |
| `src/csqtt_link_bridge.rs` | новый: обёртка `parse()` |
| `src/config.rs` | `parse_csqtt()` — приоритет csqtt-link → Lua → нативный |

### Backend/Android

| Файл | Что изменено |
|---|---|
| `Backend.kt` | `parseCsqtt()` — приоритет csqtt-link → Lua → нативный; `CsqttLink.ensureLoaded()` в `run()` |
| `CsqttLink.kt` | новый: JNI-мост к `libcsqtt_decode.so` |
| `jni_wrapper.rs` | новый: JNI-обёртки (положить в `Core/csqtt-link/src/jni_wrapper.rs`) |

### Backend/iOS

| Файл | Что изменено |
|---|---|
| `Backend.swift` | `parseLink()` — приоритет csqtt-link (staticlib) → нативный |
| `CsqttLink.swift` | новый: Swift-обёртка над staticlib |
| `csqtt_link_bridge.h` | новый: C-заголовок для bridging-header |

### Core/csqtt-link

| Файл | Что изменено |
|---|---|
| `src/lib.rs.patch.md` | как добавить JNI-модуль для Android |

## Порядок применения

### 1. Desktop

```bash
# Скопировать файлы в Backend/Desktop/
# Cargo.toml, src/main.rs, src/config.rs — перезаписать
# src/csqtt_link_bridge.rs — новый

cd Backend/Desktop
cargo build --release

### 2. OpenWRT

То же самое для `Backend/OpenWRT/`.

### 3. Android

```
# 1) Скопировать Backend.kt и CsqttLink.kt в Backend/Android/
# 2) Скопировать jni_wrapper.rs → Core/csqtt-link/src/jni_wrapper.rs
# 3) В Core/csqtt-link/Cargo.toml добавить:
#    [target.'cfg(target_os = "android")'.dependencies]
#    jni = "0.21"
# 4) В Core/csqtt-link/src/lib.rs в конец добавить:
#    #[cfg(target_os = "android")]
#    mod jni_wrapper;
# 5) CI (build.yml) уже делает всё остальное:
#    - cargo ndk build → jniLibs/<abi>/libcsqtt_decode.so
#    - копирует Backend/Android/*.kt → Frontend/android/app/src/main/kotlin/...
```

### 4. iOS

```
# 1) Скопировать Backend.swift, CsqttLink.swift, csqtt_link_bridge.h
#    в Backend/iOS/ (и в Frontend/ios/Runner/ / Tunnel/ для сборки)
# 2) В Frontend/ios/project.yml добавить:
#    LIBRARY_SEARCH_PATHS: "$(PROJECT_DIR)/Core"
#    где лежит libcsqtt_link.a (из CI-артефакта csqtt-link-iOS)
# 3) В Tunnel/LaLune-Bridging-Header.h добавить:
#    #import "csqtt_link_bridge.h"
# 4) CsqttLink.swift — в target Runner
```

## Приоритет парсеров csqtt://

1. **csqtt-link** (Rust, AES-256-GCM) — основной, самый надёжный
2. **Lua** (`csqtt_decode.lua`) — если пользователь положил файл
3. **Нативный** (plain v=2 / user:pass@host) — fallback для старых ссылок

## Проверка

```
# Desktop CLI
cd Core/csqtt-link && cargo build --release
./target/release/csqtt-link 'csqtt://e3HYC3JF...'

# Desktop backend
cd Backend/Desktop && cargo build --release

# OpenWRT
cd Backend/OpenWRT && cargo build --release --target aarch64-unknown-linux-musl

# Android (через CI)
# → APK содержит libcsqtt_decode.so и работает с новыми ссылками

# iOS (через CI)
# → libcsqtt_link.a / csqtt_link.xcframework
