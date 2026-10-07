// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SceneDelegate — создаёт окно и FlutterViewController,
// только ПОСЛЕ этого запускает Backend.
//
// ВАЖНО: если использовать AppDelegate.window напрямую (без SceneDelegate),
// Flutter.framework из `flutter build ios-framework` может не подключиться
// к окну правильно. Поэтому используем SceneDelegate + FlutterViewController.

import UIKit
import Flutter

@available(iOS 17.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var flutterVC: FlutterViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            NSLog("[LaLune] SceneDelegate: not a UIWindowScene")
            return
        }

        NSLog("[LaLune] SceneDelegate: willConnectTo")

        // 1. Создаём FlutterViewController.
        let flutterVC = FlutterViewController(
            project: nil,
            nibName: nil,
            bundle: nil
        )
        flutterVC.modalPresentationStyle = .fullScreen
        self.flutterVC = flutterVC
        NSLog("[LaLune] FlutterViewController created")

        // 2. Регистрируем плагины.
        //    GeneratedPluginRegistrant создаётся автоматически
        //    при `flutter build ios-framework` в Runner/.
        GeneratedPluginRegistrant.register(with: flutterVC)
        NSLog("[LaLune] plugins registered")

        // 3. Создаём окно и ставим rootViewController.
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = flutterVC
        window.backgroundColor = .systemBackground
        self.window = window
        window.makeKeyAndVisible()
        NSLog("[LaLune] window.rootViewController set")

        // 4. Только ТЕПЕРЬ запускаем Backend — окно уже готово,
        //    исключение не уронит приложение молча.
        Backend.shared.attach(window: window)
        do {
            try Backend.shared.run()
            NSLog("[LaLune] Backend.shared.run() called")
        } catch {
            NSLog("[LaLune] Backend.run() failed: \(error.localizedDescription)")
            // Не падаем — UI покажет баннер "Backend offline".
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        NSLog("[LaLune] SceneDelegate: sceneDidDisconnect")
        Backend.shared.stop()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        NSLog("[LaLune] SceneDelegate: sceneDidBecomeActive")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        NSLog("[LaLune] SceneDelegate: sceneWillResignActive")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        NSLog("[LaLune] SceneDelegate: sceneWillEnterForeground")
        // Backend мог быть убит системой в фоне — перезапускаем.
        do {
            try Backend.shared.run()
        } catch {
            NSLog("[LaLune] Backend.run() on foreground failed: \(error.localizedDescription)")
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        NSLog("[LaLune] SceneDelegate: sceneDidEnterBackground")
    }
}

