# Android Backend (Kotlin)

`Backend.kt` — единая точка входа. Запускает HTTP-сервер на `127.0.0.1:1062`,
управляет `VpnService`, ядром CSQTT, VK-авторизацией, настройками.

## Использование

В `MainActivity.onCreate()`:

```
Backend(this).run()
```

`run()` синхронный — стартует HTTP-сервер в фоне, регистрирует все роуты,
готов к приёму запросов от Flutter UI.

## Структура

```
com.lalune.backend/
├── Backend.kt          # Главный класс + run()
├── HttpServer.kt       # Мини-сервер на ServerSocket
├── Routes.kt           # Все endpoint'ы
├── StateStore.kt       # SQLite + settings.json + token.json
├── CoreManager.kt      # Скачивание/запуск ядра CSQTT
├── VkApi.kt            # VK API клиент + авторизация
├── EventBus.kt         # SSE / event broadcast
└── VpnTunnel.kt        # UDP-мост к ядру (TUN в VpnService)
```

## TUN

Android использует `VpnService.Builder` для поднятия TUN. UDP-мост — как в
текущей версии: два потока, TUN ↔ UDP ↔ ядро.

## Файлы данных

Все файлы в `context.filesDir/la-lune/`:

- `configs.db` (SQLite)
- `settings.json`
- `token.json`
- `logs.log`
- `LATEST`
- ядро (`libclient-android-*.so` в `nativeLibraryDir`)

## Разрешения (AndroidManifest.xml)

```
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```