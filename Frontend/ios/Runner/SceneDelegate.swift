// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SceneDelegate должен показывать Flutter UI. Раньше здесь создавался
// пустой UIViewController, из-за чего iOS мог показывать чёрный экран
// несмотря на успешно запущенный Backend.

import Flutter
import UIKit

@available(iOS 17.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            NSLog("[LaLune] SceneDelegate: no UIWindowScene")
            return
        }

        let window = UIWindow(windowScene: windowScene)
        let flutterController = FlutterViewController()
        window.rootViewController = flutterController
        self.window = window
        window.makeKeyAndVisible()

        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.attach(window: window)
        }
        NSLog("[LaLune] Flutter root view controller attached")
    }
}
