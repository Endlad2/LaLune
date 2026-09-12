# Frontend (Dart/Flutter Web)

## Структура

```

Frontend/
├── Core/              — Dart/Flutter-проект (весь UI)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── api.dart          — обёртки над window.api
│   │   ├── theme.dart
│   │   ├── pages/
│   │   └── widgets/
│   ├── web/
│   │   └── index.html
│   └── pubspec.yaml
├── Api/               — JS-мостики (по одному на платформу)
│   ├── desktop.js
│   ├── android.js
│   ├── openwrt.js
│   └── ios.js
└── output/            — сюда собирается всё
├── index.html
├── api.js         ← копия одного из Api/*.js
├── assets/
├── main.dart.js
└── flutter.js

```

## Сборка

```bash
# Android / iOS
python build_frontend.py --platform Android
python build_frontend.py --platform IOS

# Desktop
python build_frontend.py --platform Linux
python build_frontend.py --platform Windows

# OpenWRT (пока заглушка)
python build_frontend.py --platform OpenWRT
```

Результат — в `Frontend/output/`. Он используется:

- Android → копируется в `Mobile/Android/app/src/main/assets/`
- Desktop → копируется в `Desktop/<platform>/frontend/` (делает `build_desktop.py`)
- OpenWRT/iOS → пока не подключено к сборке

## Контракт `window.api`

Все `Api/*.js` обязаны иметь функции с этими именами (Dart вызывает их напрямую):

| Функция ↕▾ | Возвращает ↕▾ |
|---|---|
| −`GetConfigsJson()` | `string` (JSON array) |
| −`SaveConfig(link)` | `bool` |
| −`DeleteConfig(id)` | `bool` |
| −`GetSettingsJson()` | `string` (JSON object) |
| −`SaveSettings(json)` | `bool` |
| −`GetLogsJson()` | `string` (JSON array of strings) |
| −`ClearLogs()` | `bool` |
| −`GetStatusJson()` | `string` (`{"connected":bool}`) |
| −`Connect(id)` | `bool` |
| −`Disconnect()` | `bool` |
| −`CheckUpdate()` | `string` (`{"update":bool,"version":"..."}`) |
| −`UpdateCore()` | `bool` |
| −`UpdateCoreAndWait()` | `bool` |
| −`GetDeviceId()` | `string` |
| −`RegenerateDeviceId()` | `string` (новый ID) |
⚙

## Про async-платформы (Wails)

Wails возвращает `Promise`. Dart-код ожидает синхронный ответ.
`desktop.js` решает это кэшем: в фоне каждые 1.5 сек перечитывает
актуальное состояние через `window.go.main.App.*`, а Dart читает из кэша.

## Про Assets

Картинки лежат в `Assets/` в корне проекта, `build_frontend.py`
копирует их в `Frontend/output/assets/` при сборке. В Dart — по путям:

```
Image.asset('assets/background.png')
Image.asset('assets/lune.png')
Image.asset('assets/connect.png')
Image.asset('assets/settings.png')
Image.asset('assets/info.png')
Image.asset('assets/logs.png')
```

## Стилистические правила

- Никаких плашек и «пакетов» над фоном — фон `background.png` виден везде
- Все карточки/списки — `GlassCard` (прозрачный фон + blur + рамка)
- Все кнопки: hover → scale 0.92–0.94 и подсветка
- Навбар: прозрачный, blur 18, рамка, высота 56
- Переход между страницами: fade + slide 4% вверх, 280 ms
- Модалки: не `confirm()`, а `showDialog` с `AlertDialog` в тёмной теме
- Obfs: только `video` и `audio` (никакого `text`)
- В настройках НЕТ Turn Host/Port — они не имеют смысла для CSQTT

