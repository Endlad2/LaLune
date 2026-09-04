# LaLune iOS

## Структура

```

Mobile/IOS/
├── project.yml              — Конфигурация XcodeGen
├── ExportOptions.plist      — Настройки экспорта IPA
├── build.sh                 — Скрипт сборки
├── Core/
│   ├── csqtt_bridge.h       — C-интерфейс ядра
│   ├── libcsqtt_core.a      — Сюда положить скомпилированное ядро
│   └── module.modulemap     — Swift module map
└── Sources/
├── App/
│   ├── AppDelegate.swift
│   ├── ViewController.swift
│   └── Info.plist
└── Tunnel/
├── PacketTunnelProvider.swift
└── Info.plist

```

## Требования

- macOS с Xcode 15+
- XcodeGen (`brew install xcodegen`)
- Rust для сборки ядра
- `libcsqtt_core.a` в `Core/`

## Сборка ядра (.a)

```bash
cd /path/to/csqtt-core
cargo build --release --target aarch64-apple-ios
cp target/aarch64-apple-ios/release/libcsqtt_core.a ../Mobile/IOS/Core/
```

## Сборка IPA

```
./build.sh
```

## App Group

Необходимо настроить App Group `group.com.lalune` в Apple Developer Portal.

## Для AltStore

IPA собирается с `method=ad-hoc`. Пользователь подписывает через AltStore.

