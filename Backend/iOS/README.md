# iOS Backend (Swift)

`Backend.swift` — точка входа. HTTP-сервер на `127.0.0.1:1062`,
управляет `NETunnelProviderManager`, ядром CSQTT, VK-авторизацией.

## Требования

- iOS 17.0+
- App Group `group.com.lalune`
- Network Extension entitlement

## Файлы

| Файл ↕▾ | Назначение ↕▾ |
|---|---|
| −`Backend.swift` | HTTP-сервер + все роуты |
| −`HttpServer.swift` | Сервер на Network.framework |
| −`PacketTunnelProvider.swift` | Network Extension: csqtt_run + UDP-мост |
| −`CoreManager.swift` | Скачивание ядра + парсинг логов |
| −`VkWebViewController.swift` | WKWebView для OAuth ВК |
⚙

## Использование

```
// AppDelegate.application(_:didFinishLaunchingWithOptions:)
Backend.shared.attach(window: window)
Backend.shared.run()
```

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

## Почему не `ASWebAuthenticationSession`

`ASWebAuthenticationSession` не даёт перезагрузить URL внутри одной сессии —
только close + new instance. Нам нужен цикл silent_token → vk.com → AUTH_URL
**в том же WebView** (как на Android). Поэтому — свой `WKWebView` с
`WKWebsiteDataStore.default()` (persistent cookies, общие с Safari).

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