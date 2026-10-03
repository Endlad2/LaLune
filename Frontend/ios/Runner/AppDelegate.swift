// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Классический AppDelegate для Flutter 3.29.
//
// НЕ использует FlutterImplicitEngineDelegate / FlutterImplicitEngineBridge —
// эти типы доступны только при сборке через `flutter build ios` (или
// Runner.xcodeproj от flutter create), но НЕ экспортируются в
// Flutter.framework, который создаётся `flutter build ios-framework`.
//
// Приложение поднимает Backend (HTTP API) на 127.0.0.1:1062 и следит за
// его жизнью каждые 3 секунды.

import Flutter
import UIKit
import NetworkExtension
import BackgroundTasks
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {

    private var backend: Backend?
    private var watchdogTimer: Timer?

    private let API_URL = URL(string: "http://127.0.0.1:1062/ping")!
    private let BG_TASK_ID = "com.lalune.app.refresh"

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        registerBackgroundTask()
        requestNotificationPermission()

        // Стартуем Backend (HTTP API).
        let b = Backend.shared
        b.attach(window: self.window)
        b.run()
        self.backend = b
        NSLog("[LaLune] Backend.run() called")

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
    //  Watchdog
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
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            guard let self = self else { return }
            let ok = (resp as? HTTPURLResponse).map {
                (200..<300).contains($0.statusCode)
            } ?? false
            if !ok {
                NSLog("[LaLune] API not responding — restarting backend")
                DispatchQueue.main.async { self.restartBackend() }
            }
        }.resume()
    }

    private func restartBackend() {
        backend?.stop()
        let b = Backend.shared
        b.attach(window: self.window)
        b.run()
        backend = b
        NSLog("[LaLune] Backend restarted")
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
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }
            let ok = (resp as? HTTPURLResponse).map {
                (200..<300).contains($0.statusCode)
            } ?? false
            if !ok {
                DispatchQueue.main.async { self.restartBackend() }
            }
            task.setTaskCompleted(success: true)
        }.resume()
    }
}
