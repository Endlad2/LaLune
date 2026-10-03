// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Минимальный SceneDelegate.
//
// НЕ использует FlutterSceneDelegate — этот тип недоступен в
// Flutter.framework от `flutter build ios-framework`.

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: windowScene)
        w.rootViewController = UIViewController()
        self.window = w
        w.makeKeyAndVisible()
    }
}
