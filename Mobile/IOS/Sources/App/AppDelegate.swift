// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// AppDelegate — iOS-точка входа с FlutterViewController + MethodChannel.
// Реальная логика (VPN, token) — в Swift-классах, как и было.
// MethodChannel пока возвращает заглушки — заполним позже.

import UIKit
import Flutter

@main
class AppDelegate: FlutterAppDelegate {
    var window: UIWindow?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = FlutterViewController(
            project: nil, nibName: nil, bundle: nil)
        let channel = FlutterMethodChannel(
            name: "com.lalune.app/bridge",
            binaryMessenger: controller.binaryMessenger)

        FlutterBridge.shared.register(on: channel)

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
