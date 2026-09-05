# LaLune

[![GitHub Stars](https://img.shields.io/github/stars/Endlad2/LaLune?style=flat-square)](https://github.com/Endlad2/LaLune/stargazers)
[![Latest Release](https://img.shields.io/github/v/release/Endlad2/LaLune?style=flat-square)](https://github.com/Endlad2/LaLune/releases)

Кроссплатформенный VPN-клиент для протокола CSQTT. Приложение объединяет в себе Desktop (Windows/Linux), мобильную (iOS) и роутерную (OpenWRT) версии с единым UI на HTML/CSS/JS.

## О проекте

LaLune — клиент для обхода блокировок на базе протокола [CSQTT](https://github.com/Endlad2/csqtt-core). Протокол использует VK Calls для маскировки трафика, TURN для обхода NAT, WRAP для шифрования и обфускацию для сокрытия.

### Поддерживаемые платформы

| Платформа | Статус | Технология |
|---|---|---|
| Windows | Готово | Wails v2 + Wintun |
| Linux | Готово | Wails v2 + TUN |
| OpenWRT | Готово | Go daemon |
| iOS | Готово | Swift + Network Extension |

## Архитектура

```

LaLune/
├── Frontend/          — общий HTML/CSS/JS UI
├── Desktop/           — Wails-приложение (Windows/Linux)
│   ├── Libs/          — общая Go-логика (БД, конфиги, обновления)
│   ├── Windows/       — Windows-специфичный код
│   └── Linux/         — Linux-специфичный код
├── Mobile/
│   └── IOS/           — iOS-приложение (Swift + Network Extension)
├── OpenWRT/           — демон для роутеров
└── build_desktop.py   — скрипт сборки Desktop

```

## Сборка Desktop

### Требования

- Go 1.22+
- Wails v2 (`go install github.com/wailsapp/wails/v2/cmd/wails@latest`)
- Python 3.10+

### Windows

```bash
python build_desktop.py --platform Windows
```

### Linux

```
# Установить зависимости
sudo apt-get install libgtk-3-dev libwebkit2gtk-4.0-dev

python build_desktop.py --platform Linux
```

## Сборка OpenWRT

```
cd OpenWRT

# ARM64
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o csqtt-client-arm64 main.go

# ARMv7
GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -ldflags="-s -w" -o csqtt-client-armv7 main.go
```

## Сборка iOS

```
cd Mobile/IOS

# Установить XcodeGen
brew install xcodegen

# Сгенерировать проект
xcodegen generate

# Собрать unsigned IPA
xcodebuild \
  -project LaLune.xcodeproj \
  -scheme LaLune \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

IPA устанавливается через AltStore или Scarlet.

## Формат ссылки подключения

```
csqtt://connect?v=2&host=HOST&peer=PORT&password=PASSWORD&hashes=HASH1+HASH2+HASH3
```

> [!WARNING]
> **Некоммерческий статус и запрет коммерческого использования**
> Проект является строго некоммерческим исследовательским инструментом и не преследует извлечения выгоды.
> 
> Я и (**amurcanov**) прямо запрещаю любое использование исходного кода данного репозитория ([github.com/amurcanov/csqtt](https://github.com/amurcanov/csqtt)) в коммерческих целях в соответствии с условиями лицензии **PolyForm Noncommercial License 1.0.0**. Любая продажа, перепродажа, интеграция в платные сервисы или извлечение прибыли на базе данного кода запрещены.


Ядро CSQTT: [github.com/Endlad2/csqtt-core](https://github.com/Endlad2/csqtt-core)

## Автор

- LaLune: Endlad7373
- CSQTT: amurcanov
