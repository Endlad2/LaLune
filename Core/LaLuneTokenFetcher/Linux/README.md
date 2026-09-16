# LaLuneTokenFetcher — Linux

Точка входа для Linux. WebView2 там не работает, поэтому открытие окна
авторизации делегируется нативному C-хелперу `la-lune-webview-helper`
(GTK + WebKitGTK), который читает URL из аргументов и печатает
`access_token` в stdout.

## Как это работает

```
┌────────────────────────┐        ┌─────────────────────────────┐
│  LaLuneTokenFetcher    │  exec  │  la-lune-webview-helper     │
│  (C#, .NET 8)          │───────▶│  (C, GTK + WebKitGTK)       │
│                        │        │                             │
│  ITokenFetcher  ───────┼── argv │  открывает окно 500x700     │
│                        │        │  Navigate(AuthUrl)          │
│                        │        │  notify::uri / load-changed │
│                        │        │  + g_timeout_add(3000)      │
│                        │        │                             │
│                        │◀──stderr  [helper] URL: <url>        │
│  переносит в stdout    │        │  (раз в 3 секунды)          │
│  как [LaLune] URL: ... │        │                             │
│                        │◀──stdout  TOKEN:<access_token>       │
│  TokenStorage.Save  ───┼───     │                             │
│  → ~/.la-lune/token.json        │  exit 0                     │
└────────────────────────┘        └─────────────────────────────┘
```

Хелпер слушает `notify::uri`, `load-changed` и таймер (3 секунды) —
при смене URL печатает его в stderr с префиксом `[helper] URL:`, а при
переходе на `blank.html` вытаскивает `access_token` из фрагмента и
печатает его в stdout. Тайм-аут — 5 минут, как в оригинальном Flutter-коде.

C#-сторона читает stderr построчно, строки вида `[helper] URL: ...`
перекладывает в свой stdout как `[LaLune] URL: ...` — чтобы пользователь
видел ту же динамику, что и в Windows-версии.

## Сборка

### Через Python-скрипт (рекомендуется)

Из корня проекта:

```
python build_token_grabber.py --platform=Linux
```

Скрипт соберёт нативный хелпер, опубликует C#-бинарник и положит результат
в `output/LaLuneTokenFetcher/`.

### Вручную

```
cd Linux && ./build.sh
```

Скрипт:

1. Проверяет gcc, .NET SDK и наличие dev-пакетов GTK/WebKitGTK.
2. Компилирует `native/la-lune-webview-helper.c` в `native/la-lune-webview-helper`.
3. Запускает `dotnet publish` для `LaLuneTokenFetcher.Linux.csproj`.
4. Копирует хелпер в publish-папку.

## Зависимости

**Debian / Ubuntu:**

```
sudo apt install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev
```

**Fedora / RHEL:**

```
sudo dnf install gcc pkg-config gtk3-devel webkit2gtk4.1-devel
```

**Arch / Manjaro:**

```
sudo pacman -S base-devel pkg-config gtk3 webkit2gtk-4.1
```

**.NET 8 SDK:**

```
sudo apt install dotnet-sdk-8.0
# или
curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0
```

## Запуск

```
output/LaLuneTokenFetcher/LaLuneTokenFetcher
```

Откроется окно 500×700. В терминале раз в 3 секунды будет печататься
текущий URL:

```
[LaLune] URL: https://oauth.vk.ru/authorize?client_id=7793118&...
[LaLune] URL: https://oauth.vk.ru/login?act=login&...
[LaLune] URL: https://oauth.vk.ru/blank.html#access_token=vk1.a.xxxx&expires_in=0&user_id=...
[LaLune] Токен сохранён: /home/you/.la-lune/token.json
```

## Почему нативный хелпер, а не WebKitGTK в C#?

Официальных .NET-биндингов к WebKitGTK нет. `GtkSharp` жив, но
`WebKitGtkSharp` заброшен с 2017 года, а `Gir.Core` требует
генерации биндингов через `gir2sharp` и работает нестабильно.
200 строк нативного C проще поддерживать, чем бороться с генератором
биндингов, который ломается на каждом втором обновлении GObject Introspection.

## Коды возврата

| Код ↕▾ | Значение ↕▾ |
|---|---|
| −0 | Успех, токен сохранён |
| −1 | Критическая ошибка (хелпер не найден, GTK не поднялся) |
| −3 | Тайм-аут 5 минут или окно закрыто до получения |
⚙