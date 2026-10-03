// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// iOS runner: запускает Backend (HTTP API + управление NETunnelProviderManager),
// следит за API каждые 3 сек и перезапускает, если процесс упал/убит системой.

import Flutter
import UIKit
import NetworkExtension
import BackgroundTasks
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

    private var backend: Backend?
    private var watchdogTimer: Timer?
    private var methodChannel: FlutterMethodChannel?

    private let API_URL = URL(string: "http://127.0.0.1:1062/ping")!
    private let CHANNEL = "com.lalune/native"
    private let BG_TASK_ID = "com.lalune.app.refresh"

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 1. Регистрируем фоновую задачу (для периодического «пинга» API).
        registerBackgroundTask()

        // 2. Просим разрешение на уведомления (нужно VpnService).
        requestNotificationPermission()

        // 3. Стартуем Backend — он поднимает HTTP API на 127.0.0.1:1062.
        let b = Backend.shared
        b.attach(window: self.window)
        b.run()
        self.backend = b
        NSLog("[LaLune] Backend.run() called")

        // 4. Watchdog: каждые 3 сек проверяем, что API живой.
        startApiWatchdog()

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        // MethodChannel для Flutter: isBackendAlive / restartBackend / requestVpnPermission
        let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LaLuneNative")!
        let channel = FlutterMethodChannel(
            name: CHANNEL,
            binaryMessenger: registrar.messenger()
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            switch call.method {
            case "isBackendAlive":
                self.isBackendAlive { alive in result(alive) }
            case "restartBackend":
                self.restartBackend()
                result(true)
            case "requestVpnPermission":
                self.requestVpnPermission { ok in result(ok) }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        self.methodChannel = channel
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
    //  Watchdog: каждые 3 сек проверяем /ping
    // ============================================================

    private func startApiWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) {
            [weak self] _ in
            self?.checkApi()
        }
    }

    private func checkApi() {
        isBackendAlive { [weak self] alive in
            guard let self = self else { return }
            if !alive {
                NSLog("[LaLune] API not responding — restarting backend")
                DispatchQueue.main.async {
                    self.restartBackend()
                }
            }
        }
    }

    private func isBackendAlive(completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: API_URL)
        req.timeoutInterval = 1.5
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                completion(true)
            } else {
                completion(false)
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
    //  VPN permission: на iOS это NETunnelProviderManager.
    //  Реально разрешение спрашивает система при первом startVPNTunnel().
    //  Мы просто проверяем, что extension зарегистрирован.
    // ============================================================

    private func requestVpnPermission(completion: @escaping (Bool) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                NSLog("[LaLune] loadAllFromPreferences: \(error.localizedDescription)")
                completion(false)
                return
            }
            completion(true)
        }
    }

    // ============================================================
    //  Background task: iOS может прибить процесс — BGTask даст немного
    //  времени, чтобы API успел ответить на запросы. Не даёт жить
    //  вечно, но снижает вероятность «отвалилось в фоне».
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
        // Сразу планируем следующий.
        scheduleBackgroundRefresh()

        task.expirationHandler = {
            self.watchdogTimer?.invalidate()
        }

        // Проверяем и, если надо, поднимаем API.
        isBackendAlive { [weak self] alive in
            guard let self = self else { return }
            if !alive {
                self.restartBackend()
            }
            task.setTaskCompleted(success: true)
        }
    }
}
