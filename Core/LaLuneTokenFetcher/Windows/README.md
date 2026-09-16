# LaLuneTokenFetcher — Windows

Точка входа для Windows. Использует `Microsoft.Web.WebView2` — встроенный
в Windows 10/11 движок Edge. Полученный токен сохраняется через
`LaLuneTokenFetcher.Core.TokenStorage`.

## Сборка

```
python build_token_grabber.py --platform=Windows
```

Скрипт соберёт `LaLuneTokenFetcher.exe` и положит его в
`output/LaLuneTokenFetcher/`.

Либо вручную:

```
dotnet publish Windows/LaLuneTokenFetcher.Windows.csproj -c Release -r win-x64
```

Параметры `SelfContained`, `PublishSingleFile`, `IncludeNativeLibrariesForSelfExtract`
уже прописаны в `.csproj`, поэтому указывать их не нужно.

## Требования

- Windows 10 (с установленным [WebView2 Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)) или Windows 11 (встроен).
- .NET 8 SDK для сборки.

## Что делает

1. `Program.Main` вручную настраивает WinForms
(`EnableVisualStyles`, `SetCompatibleTextRenderingDefault`, `SetHighDpiMode`).
2. Создаётся окно 500×700 с WebView2.
3. `Navigate(AuthUrl)` — страница авторизации VK.
4. **Каждые 3 секунды** опрашивается:

- `window.location.href` — печатается в терминал как `[LaLune] URL: ...`
- `window.location.hash` — печатается как `[LaLune] HASH: ...`
- `document.URL`
5. Плюс мгновенный перехват через `NavigationStarting` и `SourceChanged`.
6. При переходе на `blank.html` токен извлекается из `href`, `hash`
или `document.URL` (фрагмент иногда теряется в `href`, но остаётся
в `hash` — поэтому проверяются все три источника).
7. `TokenStorage.Save` → `%APPDATA%\.la-lune\token.json`.

## Что видно в терминале

```
[LaLune] URL: https://oauth.vk.ru/authorize?client_id=7793118&...
[LaLune] URL: https://oauth.vk.ru/login?act=login&...
[LaLune] URL: https://oauth.vk.ru/blank.html#access_token=vk1.a.xxxx&expires_in=0&user_id=...
[LaLune] HASH: #access_token=vk1.a.xxxx&expires_in=0&user_id=...
[LaLune] Токен получен, закрываю окно.
[LaLune] Токен сохранён: C:\Users\you\AppData\Roaming\.la-lune\token.json
```

## Заметки по конфигурации

- **`ApplicationConfiguration.Initialize()` не используется.** Этот метод
генерируется source generator'ом WinForms SDK. При наличии предупреждения
MSB3277 (конфликт `WindowsBase` 4.0 из `Microsoft.NETCore.App.Ref`
и 5.0 из WPF-сборки `Microsoft.Web.WebView2.Wpf.dll`) кодогенератор может
не сработать, что приводит к ошибке `CS0234`. Ручная настройка WinForms
из трёх строк полностью снимает эту зависимость.
- **`ApplicationHighDpiMode=PerMonitorV2`** задан в `.csproj` вместо
`app.manifest`. Устраняет предупреждение `WFAC010`.
- **`MSB3277` подавлено через `NoWarn`** — предупреждение шумное и
безвредное для WinForms-сборки (WPF-часть пакета всё равно не грузится).