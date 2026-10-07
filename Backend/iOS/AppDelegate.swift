// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// AppDelegate — минимальный. Вся работа с окном и Backend — в SceneDelegate.
//
// ВАЖНО: НЕ вызывай Backend.shared.run() здесь — окно ещё не создано,
// FlutterViewController не подключён, и любое исключение уронит приложение
// молча (ты увидишь чёрный экран).

import Flutter
import UIKit
import NetworkExtension
import BackgroundTasks
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {

    private var watchdogTimer: Timer?
    private let API_URL = URL(string: "http://127.0.0.1:1062/ping")!
    private let BG_TASK_ID = "com.lalune.app.refresh"

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        NSLog("[LaLune] AppDelegate: didFinishLaunchingWithOptions")

        // Регистрируем background task — можно и здесь, окно для этого не нужно.
        registerBackgroundTask()

        // Разрешение на уведомления — тоже можно здесь.
        requestNotificationPermission()

        // ВАЖНО: Backend здесь НЕ запускаем. Это делает SceneDelegate,
        // когда окно уже создано и rootViewController установлен.
        //
        // Если запустить здесь — self.window == nil (при использовании
        // SceneDelegate окно создаёт SceneDelegate, а не AppDelegate),
        // и Backend не сможет корректно стартовать.

        // Watchdog можно запускать и здесь — он просто пингует /ping.
        startApiWatchdog()

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ============================================================
    //  Уведомления
    // ============================================================

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                NSLog("[LaLune] notifications: \(error.localizedDescription)")
            } else {
                NSLog("[LaLune] notifications granted=\(granted)")
            }
        }
    }

    // ============================================================
    //  Watchdog (только пинг, без перезапуска окна)
    // ============================================================

    private func startApiWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) {
            [weak self] _ in
            self?.checkApi()
        }
    }

    private func checkApi() {
        var req = URLRequest(url: API_URL)
        req.timeoutInterval = 1.5
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse).map {
                (200..<300).contains($0.statusCode)
            } ?? false
            if !ok {
                NSLog("[LaLune] API not responding")
                // НЕ перезапускаем здесь — SceneDelegate сам перезапустит
                // при sceneWillEnterForeground.
            }
        }.resume()
    }

    // ============================================================
    //  Background task
    // ============================================================

    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BG_TASK_ID,
            using: nil
        ) { task in
            self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BG_TASK_ID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("[LaLune] BGTask submit failed: \(error.localizedDescription)")
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        task.expirationHandler = {
            self.watchdogTimer?.invalidate()
        }
        var req = URLRequest(url: API_URL)
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse).map {
                (200..<300).contains($0.statusCode)
            } ?? false
            task.setTaskCompleted(success: ok)
        }.resume()
    }
}

