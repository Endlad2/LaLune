# Структура lib/

```
lib/
├── main.dart                 # RootShell + MaterialApp
│
├── api/                      # HTTP клиент к 127.0.0.1:1062
│   ├── api_client.dart       # GET/POST/PUT/PATCH/DELETE
│   ├── api_exception.dart
│   └── sse_client.dart       # SSE-подписка на /events
│
├── models/                   # Dart-модели (парсинг JSON)
│   ├── config_item.dart
│   ├── settings.dart
│   ├── vpn_status.dart
│   ├── vk_token_state.dart
│   ├── core_info.dart
│   ├── update_info.dart
│   └── log_line.dart
│
├── state/                    # Riverpod
│   ├── providers.dart        # apiClientProvider
│   ├── configs_notifier.dart # список конфигов + selected
│   ├── settings_notifier.dart
│   ├── vpn_notifier.dart     # подписка на SSE status
│   ├── logs_notifier.dart    # SSE log stream
│   └── vk_notifier.dart      # поллинг /vk/token/state
│
├── theme/
│   ├── app_theme.dart        # ThemeData
│   ├── glass.dart            # BoxDecoration для GlassCard
│   └── assets.dart           # пути к PNG
│
├── pages/
│   ├── connection_page.dart  # луна + селектор конфигов
│   ├── settings_page.dart    # настройки + авторизация
│   ├── logs_page.dart        # логи
│   ├── info_page.dart        # информация + обновления
│   └── add_config_dialog.dart
│
└── widgets/
    ├── glass_card.dart
    ├── moon_button.dart
    ├── navbar.dart
    ├── toast.dart
    ├── config_selector.dart
    └── input_row.dart
```

## Как общается с бэкендом

`ApiClient` ходит на `http://127.0.0.1:1062`. Бэкенд — платформенный
(Desktop Rust / Android Kotlin / iOS Swift), все они реализуют
**одинаковый REST API** (см. `Backend/API.md`).

SSE подписка (`SseClient`) — на `/events`. Основные типы событий:

- `log` — строка лога
- `status` — `{connected: bool}` (VPN)
- `progress` — `{kind, percent}` (скачивание ядра, VK-токен)
- `event` — именованные (`tun_ready`, `deploy_done`)
- `error` — `{message}`