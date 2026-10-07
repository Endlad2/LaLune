# iOS Backend (Swift) — обновлённая версия

`Backend.swift` — точка входа. HTTP-сервер на `127.0.0.1:1062`,
управляет `NETunnelProviderManager`, ядром CSQTT, VK-авторизацией.

## Требования

- iOS 17.0+
- App Group `group.com.lalune`
- Network Extension entitlement
- `SceneDelegate` (см. `SceneDelegate.swift`)

## Файлы

| Файл ↕▾ | Назначение ↕▾ |
|---|---|
| −`Backend.swift` | HTTP-сервер + все роуты |
| −`HttpServer.swift` | Сервер на Network.framework |
| −`SceneDelegate.swift` | Создаёт окно + FlutterViewController, запускает Backend |
| −`AppDelegate.swift` | Минимальный — только уведомления и background task |
| −`PacketTunnelProvider.swift` | Network Extension: csqtt_run + UDP-мост |
| −`CoreManager.swift` | Скачивание ядра + парсинг логов |
| −`VkWebViewController.swift` | WKWebView для OAuth ВК |
⚙

## Запуск

```
// AppDelegate.didFinishLaunchingWithOptions:
//   НЕ вызывай Backend.shared.run() здесь! Окно ещё не создано.

// SceneDelegate.scene(_:willConnectTo:options:):
let flutterVC = FlutterViewController(project: nil, nibName: nil, bundle: nil)
GeneratedPluginRegistrant.register(with: flutterVC)
let window = UIWindow(windowScene: windowScene)
window.rootViewController = flutterVC
window.makeKeyAndVisible()
Backend.shared.attach(window: window)
try Backend.shared.run()   // теперь throws
```

## Почему не в AppDelegate

При использовании `SceneDelegate` (а он нужен для iOS 17+ с
`UIApplicationSceneManifest`) `AppDelegate.window` **не устанавливается
автоматически**. Если вызвать `Backend.shared.run()` в
`didFinishLaunchingWithOptions`, окно будет `nil`, а любое исключение
уронит приложение молча → чёрный экран.

## Backend.run() теперь throws

```
public func run() throws {
    guard !running else { return }
    if !isPortAvailable(port: PORT) {
        throw BackendError.portBusy(PORT)
    }
    // ... HttpServer.start() тоже throws
}
```

`SceneDelegate` ловит исключение в `do/catch` и показывает баннер
«Backend offline» вместо краша.

## VK-авторизация

`POST /vk/token/login` — Backend сам открывает **свой `WKWebView`**
(`VkWebViewController`), ждёт токен, сохраняет в `token.json`.

**Цикл** (как в Desktop PlaywrightTokenFetcher и Android VkWebViewFetcher):

- **Pass 1:** если VK вернул `#payload=...` (silent_token), WebView **не закрывается**.
Показывается оверлей «Получаем токен, подождите...», `webView.load("https://vk.com/")`,
через 2 секунды — `webView.load(AUTH_URL)` в **том же** WKWebView.
- **Pass 2:** VK видит cookies активной сессии (`WKWebsiteDataStore.default()`)
→ показывает «Продолжить как Имя» → возвращает `access_token`.
- Если и на Pass 2 пришёл silent_token — сдаёмся с ошибкой.

Flutter просто поллит `GET /vk/token/state`.

## Entitlements

**Основное приложение** (`.entitlements`):

```
<key>com.apple.security.application-groups</key>
<array><string>group.com.lalune</string></array>
```

**Tunnel Extension**:

```
<key>com.apple.developer.networking.networkextension</key>
<array><string>packet-tunnel-provider</string></array>
<key>com.apple.security.application-groups</key>
<array><string>group.com.lalune</string></array>
```

## Troubleshooting

### Чёрный экран

См. `FIX-BlackScreen.md`. Кратко:

1. `Backend.run()` не в `AppDelegate`, а в `SceneDelegate` — после `makeKeyAndVisible()`.
2. `rootViewController` — `FlutterViewController`, а не пустой `UIViewController`.
3. `GeneratedPluginRegistrant.register(with:)` вызван.
4. `Info.plist` → `UISceneDelegateClassName = $(PRODUCT_MODULE_NAME).SceneDelegate`.

### Backend offline баннер

`Backend.run()` бросил исключение. Смотри Console.app:

```
[LaLune] Backend.run() failed: Порт 1062 занят
```

Скорее всего приложение уже запущено, или порт занят другим процессом.

### Уведомления не приходят

Проверь `UNUserNotificationCenter.current().getNotificationSettings()` —
если `.authorizationStatus == .denied`, пользователь отклонил.
Веди его в Settings → LaLune → Уведомления.