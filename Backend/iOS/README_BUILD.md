# Сборка iOS backend

## Требования

- Xcode 15+
- iOS 17.0+ target
- App Group `group.com.lalune`
- Entitlements: Network Extension

## Интеграция

1. Добавить `Backend.swift` и `HttpServer.swift` в основной target.
2. Вызвать `Backend.shared.run()` в `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
3. В `PacketTunnelProvider` использовать `group.com.lalune` для обмена настройками.

## Entitlements

**Основное приложение:**

```
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.lalune</string>
</array>
```

**Tunnel Extension:**

```
<key>com.apple.developer.networking.networkextension</key>
<array>
    <string>packet-tunnel-provider</string>
</array>
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.lalune</string>
</array>
```

## Info.plist (Tunnel)

```
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.networkextension.packet-tunnel</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
</dict>
```