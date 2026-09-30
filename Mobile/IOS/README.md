# LaLune iOS

## Структура

```

Mobile/IOS/
├── project.yml              — XcodeGen конфигурация
├── Core/
│   ├── csqtt_bridge.h       — C-интерфейс ядра
│   ├── libcsqtt_ios_core.a  — Скомпилированное ядро (положи сюда)
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

- Xcode 15+
- XcodeGen (`brew install xcodegen`)
- `libcsqtt_ios_core.a` в `Core/`

## Скачивание ядра

```bash
cd Mobile/IOS/Core
curl -L -o libcsqtt_ios_core.a \
  https://github.com/Endlad2/csqtt-core/releases/download/2026.09.05.07.28/libcsqtt_ios_core.a
```

## App Group

Настроить `group.com.lalune` в Apple Developer Portal.

## Сборка

```
cd Mobile/IOS
xcodegen generate
xcodebuild -project LaLune.xcodeproj -scheme LaLune -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Для AltStore

IPA собирается unsigned — AltStore подпишет при установке.

