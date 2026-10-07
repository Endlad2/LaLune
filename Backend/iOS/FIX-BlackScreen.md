# Фикс чёрного экрана на iOS

## Симптомы

1. Приложение запускается
2. Спрашивает разрешение на уведомления
3. Показывает **чёрный экран** навсегда
4. В `Console.app` / Xcode логах — `[LaLune] Backend.run() called`, но UI не появляется

## Причина

Три ошибки, которые складываются в чёрный экран:

### 1. `AppDelegate.didFinishLaunchingWithOptions` — `self.window` ещё `nil`

```
let b = Backend.shared
b.attach(window: self.window)   // ← self.window == nil
b.run()
```

Когда приложение использует `SceneDelegate` (а у тебя в `Info.plist` есть `UIApplicationSceneManifest`), `AppDelegate.window` **не устанавливается автоматически**. Окно создаёт `SceneDelegate` в `scene(_:willConnectTo:options:)`.

### 2. `SceneDelegate` создаёт пустой `UIViewController`

```
let w = UIWindow(windowScene: windowScene)
w.rootViewController = UIViewController()   // ← пусто!
```

`UIViewController()` без контента = чёрный экран. Flutter-движок вообще не подключается.

### 3. `Backend.run()` вызывается слишком рано

`Backend.shared.run()` поднимает `HttpServer` через `NWListener`. Если это делать до того, как окно готово, и в этот момент где-то вылетит исключение (например, порт занят), приложение падает в `didFinishLaunchingWithOptions` — но так как окна ещё нет, ты не видишь краш-лога, только чёрный экран.

## Что исправлено

### `AppDelegate.swift`

- Убран `self.window` (его больше нет как свойства — оставлен только для совместимости).
- `Backend.run()` **не вызывается** в `didFinishLaunchingWithOptions`. Вместо этого — только `Backend.shared.attach(...)` (сохраняет ссылку) и `startApiWatchdog()`.
- Реальный старт бэкенда перенесён в `SceneDelegate.scene(_:willConnectTo:options:)` — **после** того, как окно создано и `rootViewController` установлен.

### `SceneDelegate.swift`

- Создаёт `FlutterViewController` (не пустой `UIViewController`).
- Регистрирует плагины через `GeneratedPluginRegistrant.register(with:)`.
- Устанавливает `window.rootViewController = flutterVC`.
- После этого вызывает `Backend.shared.run()`.

### `Info.plist`

- `UIApplicationSceneManifest` **оставлен** — мы используем `SceneDelegate`.
- `UILaunchStoryboardName` — `LaunchScreen` (убедись, что файл есть в `Runner/Base.lproj/`).

### Дополнительно

- Все вызовы `Backend.run()` обёрнуты в `try/catch` (в Swift — `do/catch`), чтобы исключение не роняло приложение.
- `NWListener.start()` теперь логирует ошибки в `NSLog`, а не молча.
- Если `NWListener` не стартует (порт занят) — приложение **не падает**, а показывает баннер «Backend offline» в UI.

## Проверка

```
# 1. Пересобери Runner
cd Frontend/ios
xcodegen generate
xcodebuild -project Runner.xcodeproj -scheme Runner \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build build

# 2. Запусти на симуляторе
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/LaLune.app
xcrun simctl launch --console booted com.lalune.lalune
```

Ожидаемый лог:

```
[LaLune] SceneDelegate: willConnectTo
[LaLune] FlutterViewController created
[LaLune] plugins registered
[LaLune] window.rootViewController set
[LaLune] Backend.shared.run() called
[LaLune] HTTP listening on 127.0.0.1:1062
[LaLune] Backend started
```

И **UI появится** (луна + навбар), а не чёрный экран.

## Если всё ещё чёрный экран

1. **Проверь `Info.plist`** — должен быть `UILaunchStoryboardName = LaunchScreen`.
Без него iOS может показывать чёрный экран вместо лаунч-скрина.
2. **Проверь `Runner/Base.lproj/LaunchScreen.storyboard`** — он должен быть в target.
Если нет — создай пустой `UIViewController`-storyboard и добавь в `Runner` target.
3. **Проверь `GeneratedPluginRegistrant.h`** — он должен быть в `Runner-Bridging-Header.h`.
Если нет — Flutter-плагины не зарегистрируются.
4. **Запусти с `--verbose`**:

```
xcrun simctl launch --console-pty booted com.lalune.lalune
```

и смотри полный лог.