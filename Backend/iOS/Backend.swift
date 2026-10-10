// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune backend для iOS 17+.
// HTTP-сервер на 127.0.0.1:1062, NETunnelProviderManager, VK через
// собственный WKWebView (VkWebViewController).
//
// Точка входа: Backend.shared.attach(window:).run()

import Foundation
import Network
import NetworkExtension
import UIKit
import UserNotifications

@available(iOS 17.0, *)
public final class Backend {

    public static let shared = Backend()

    private let PORT: UInt16 = 1062
    private let HOST = "127.0.0.1"
    private let VERSION = "0.6.0"
    private let APP_GROUP = "group.com.lalune"
    private let TUNNEL_BUNDLE_ID = "com.lalune.app.tunnel"

    private let DEFAULT_WORKERS = 9
    private let MIN_WORKERS = 1
    private let MAX_WORKERS = 127
    private let DEFAULT_AUTO_API_WORKERS = 9
    private let MIN_AUTO_API_WORKERS = 9
    private let MAX_AUTO_API_WORKERS = 27

    private let VK_API_BASE = "https://api.vk.ru/method/"
    private let VK_API_VERSION = "5.199"

    private var window: UIWindow?

    private var appDir: URL {
        if let c = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP) {
            let d = c.appendingPathComponent("la-lune", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("la-lune", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private var settingsURL: URL { appDir.appendingPathComponent("settings.json") }
    private var tokenURL: URL { appDir.appendingPathComponent("token.json") }
    private var logsURL: URL { appDir.appendingPathComponent("logs.log") }
    private var configsURL: URL { appDir.appendingPathComponent("configs.json") }
    private var selectedConfigURL: URL { appDir.appendingPathComponent("selected_config.json") }

    private let stateQueue = DispatchQueue(label: "lalune.backend.state", attributes: .concurrent)
    private var logs: [String] = []
    private var eventSubscribers: [UUID: (String) -> Void] = [:]
    private var httpServer: HttpServer?
    private var running = false
    private var vpnConnected = false
    private var smarttunnelRunning = false
    private var coreDownloading = false
    private var activeCallIds: [String] = []

    private var vkWebVC: VkWebViewController?
    private var vkLoginInProgress = false
    private var vkLoginMessage = ""

    private var socks5Server: Socks5Server?

    // ============================================================
    //  Public API
    // ============================================================

    public func attach(window: UIWindow?) {
        self.window = window
    }

    public func run() {
        guard !running else { log("[BACKEND] already running"); return }
        running = true

        ensureDefaults()
        observeVpnStatus()

        let server = HttpServer(host: HOST, port: PORT) { [weak self] method, path, body in
            guard let self = self else { return (500, "{}") }
            return self.route(method: method, rawPath: path, body: body)
        } onSseOpen: { [weak self] send in
            guard let self = self else { return UUID() }
            let id = UUID()
            self.stateQueue.async(flags: .barrier) {
                self.eventSubscribers[id] = send
            }
            return id
        } onSseClose: { [weak self] id in
            guard let self = self else { return }
            self.stateQueue.async(flags: .barrier) {
                self.eventSubscribers.removeValue(forKey: id)
            }
        }

        self.httpServer = server
        server.start()
        log("[BACKEND] LaLune iOS backend started on http://\(HOST):\(PORT)")
    }

    public func stop() {
        running = false
        stopSocks5()
        httpServer?.stop()
        httpServer = nil
    }

    private func observeVpnStatus() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let conn = note.object as? NEVPNConnection else { return }
            let connected = conn.status == .connected
            self.vpnConnected = connected
            self.emitEvent(self.json([
                "type": "status", "connected": connected,
                "ts": Int(Date().timeIntervalSince1970),
            ]))
        }
    }

    // ============================================================
    //  Router
    // ============================================================

    private func route(method: String, rawPath: String, body: String) -> (Int, String) {
        let qIdx = rawPath.firstIndex(of: "?")
        let path = qIdx.map { String(rawPath[..<$0]) } ?? rawPath
        let query = qIdx.map { String(rawPath[rawPath.index(after: $0)...]) } ?? ""

        if method == "OPTIONS" { return (200, "{}") }

        do {
            switch (method, path) {
            case ("GET", "/ping"):
                return (200, json(["ok": true, "version": VERSION,
                                   "os": "ios", "arch": "arm64", "uptime": 0]))
            case ("GET", "/version"):
                return (200, json(["api": 1, "backend": VERSION,
                                   "core": CoreManager.shared.readLatest(),
                                   "ui": VERSION]))
            case ("POST", "/shutdown"):
                stop(); return (200, json(["ok": true]))

            case ("GET", "/configs"):
                return (200, loadConfigsJson())
            case ("GET", "/configs/selected"):
                return (200, readSelectedConfigJson() ?? "{}")
            case ("PUT", "/configs/selected"):
                if let data = body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = obj["id"] as? Int64 {
                    if let c = findConfig(id: id) {
                        writeSelectedConfig(jsonString(from: c) ?? "{}")
                        return (200, json(["ok": true]))
                    }
                    return (404, err("config not found"))
                } else {
                    clearSelectedConfig()
                    return (200, json(["ok": true]))
                }
            case ("POST", "/configs/parse"):
                let obj = (try? JSONSerialization.jsonObject(
                    with: body.data(using: .utf8) ?? Data()) as? [String: Any])
                let link = obj?["link"] as? String ?? ""
                return (200, jsonString(from: parseLink(link)) ?? "{}")
            case ("POST", "/configs"):
                return createConfig(body: body)

            case ("GET", "/settings"):
                return (200, loadSettingsJson())
            case ("PUT", "/settings"):
                return replaceSettings(body: body)
            case ("PATCH", "/settings"):
                return patchSettings(body: body)
            case ("POST", "/settings/reset"):
                saveSettings(defaultSettings())
                return (200, json(["ok": true]))

            case ("GET", "/device/id"):
                return (200, json(["deviceId": getDeviceId()]))
            case ("POST", "/device/id/regenerate"):
                let new = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                updateDeviceId(new)
                return (200, json(["deviceId": new]))
            case ("GET", "/device/info"):
                return (200, json(["os": "ios", "arch": "arm64",
                                   "hostname": UIDevice.current.name,
                                   "cores": ProcessInfo.processInfo.processorCount,
                                   "totalMemMb": Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)]))

            case ("POST", "/vpn/connect"):
                return vpnConnect(body: body)
            case ("POST", "/vpn/disconnect"):
                return vpnDisconnect()
            case ("GET", "/vpn/status"):
                return (200, json([
                    "state": vpnConnected ? "connected" : "disconnected",
                    "connected": vpnConnected,
                    "uptimeSec": 0, "configId": 0, "message": "", "since": ""
                ]))
            case ("POST", "/vpn/reconnect"):
                _ = vpnDisconnect()
                Thread.sleep(forTimeInterval: 0.3)
                return vpnConnect(body: "{}")
            case ("GET", "/vpn/stats"):
                return (200, json(["rxBytes": 0, "txBytes": 0,
                                   "rxRate": 0, "txRate": 0,
                                   "activeSessions": vpnConnected ? 1 : 0]))
            case ("GET", "/vpn/tunconf"):
                return (200, "{}")

            case ("GET", "/logs"):
                return (200, jsonArrayFromLogs())
            case ("GET", "/logs/tail"):
                let n = Int(queryValue(query, "lines") ?? "100") ?? 100
                return (200, jsonArrayFromLogs(tail: n))
            case ("DELETE", "/logs"):
                stateQueue.async(flags: .barrier) { self.logs.removeAll() }
                return (200, json(["ok": true]))
            case ("GET", "/logs/export"):
                return (200, currentLogs().joined(separator: "\n"))

            case ("GET", "/core/version"):
                return (200, json(["version": CoreManager.shared.readLatest()]))
            case ("GET", "/core/latest"):
                return (200, json(["version": CoreManager.shared.fetchLatestVersion() ?? ""]))
            case ("GET", "/core/check"):
                let local = CoreManager.shared.readLatest()
                let remote = CoreManager.shared.fetchLatestVersion() ?? ""
                return (200, json([
                    "hasUpdate": !remote.isEmpty && remote != local,
                    "local": local, "remote": remote
                ]))
            case ("POST", "/core/download/sync"):
                let ok = CoreManager.shared.downloadCore()
                return ok ? (200, json(["ok": true])) : (500, err("download failed"))
            case ("GET", "/core/path"):
                return (200, json(["path": CoreManager.shared.corePath() ?? ""]))
            case ("GET", "/core/protocols"):
                return (200, """
                [{"id":"CSQTT","displayName":"CSQTT (VK Calls)","repo":"Endlad2/csqtt-core","realtime":true,"description":"Оригинальный протокол CSQTT","coreAsset":""}]
                """)
            case ("DELETE", "/core"):
                if let p = CoreManager.shared.corePath() {
                    try? FileManager.default.removeItem(atPath: p)
                }
                return (200, json(["ok": true]))

            case ("GET", "/update/check"):
                return (200, json(["hasUpdate": false, "remoteTag": "",
                                   "localVersion": VERSION]))
            case ("GET", "/update/url"):
                return (200, json(["url": "https://github.com/Endlad2/LaLune/releases/latest"]))

            case ("GET", "/vk/token/state"):
                return (200, readVkStateJson())
            case ("POST", "/vk/token/login"):
                return vkLogin()
            case ("POST", "/vk/token/submit"):
                if let data = body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let token = obj["token"] as? String, !token.isEmpty {
                    saveVkToken(token)
                    return (200, json(["ok": true]))
                }
                return (400, err("token empty"))
            case ("GET", "/vk/token/validate"):
                let has = readVkToken() != nil
                return (200, json(["valid": has, "message": has ? "" : "no token"]))
            case ("POST", "/vk/token/fetch/cancel"):
                DispatchQueue.main.async { self.vkWebVC?.dismiss(animated: true) }
                return (200, json(["ok": true]))
            case ("DELETE", "/vk/token"):
                try? FileManager.default.removeItem(at: tokenURL)
                return (200, json(["ok": true]))

            case ("POST", "/vk/calls/start"):
                return vkCallsStart(body: body)
            case ("POST", "/vk/calls/stop"):
                return (200, json(["finished": 0]))
            case ("POST", "/vk/calls/stop-all"):
                let n = activeCallIds.count
                activeCallIds.removeAll()
                return (200, json(["finished": n]))
            case ("GET", "/vk/calls/active"):
                return (200, json(["callIds": activeCallIds]))

            case ("GET", "/smarttunnel/status"):
                return (200, json(["running": smarttunnelRunning]))
            case ("POST", "/smarttunnel/start"):
                smarttunnelRunning = true
                return (200, json(["ok": true]))
            case ("POST", "/smarttunnel/stop"):
                smarttunnelRunning = false
                return (200, json(["ok": true]))
            case ("POST", "/smarttunnel/reload"):
                return (200, json(["ok": true]))
            case ("GET", "/smarttunnel/logs"):
                return (200, "[]")
            case ("GET", "/smarttunnel/args"):
                return (200, "[]")
            case ("PUT", "/smarttunnel/args"):
                return (200, json(["ok": true]))

            case ("POST", "/deploy/run"):
                return (200, json(["stub": true, "message": "DeployManager not yet implemented"]))
            case ("GET", "/deploy/status"):
                return (200, json(["busy": false, "stub": true]))
            case ("GET", "/deploy/log"):
                return (200, json(["log": "", "stub": true]))
            case ("POST", "/deploy/cancel"):
                return (200, json(["stub": true]))
            case ("GET", "/deploy/protocols"):
                return (200, json(["protocols": [], "stub": true]))

            case ("GET", "/platform/capabilities"):
                return (200, json([
                    "canShowWebView": true, "canRunTun": true, "canDeploy": false,
                    "canAutoUpdate": false, "canSendNotifications": true,
                    "canOpenExternalUrl": true, "os": "ios", "platform": "mobile"
                ]))
            case ("POST", "/platform/open-url"):
                if let data = body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let urlStr = obj["url"] as? String, let url = URL(string: urlStr) {
                    DispatchQueue.main.async { UIApplication.shared.open(url) }
                }
                return (200, json(["ok": true]))
            case ("POST", "/platform/notify"):
                if let data = body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let title = obj["title"] as? String ?? ""
                    let bodyStr = obj["body"] as? String ?? ""
                    let content = UNMutableNotificationContent()
                    content.title = title; content.body = bodyStr
                    let req = UNNotificationRequest(identifier: UUID().uuidString,
                                                     content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(req)
                }
                return (200, json(["ok": true]))
            case ("POST", "/platform/open-path"):
                return (200, json(["ok": true]))
            case ("POST", "/platform/share"):
                return (200, json(["ok": true]))

            case ("GET", "/debug/state"):
                return (200, json([
                    "logCount": currentLogs().count,
                    "appDir": appDir.path,
                    "vpnConnected": vpnConnected
                ]))
            case ("POST", "/debug/echo"):
                return (200, body)
            case ("GET", "/debug/config"):
                return (200, json([
                    "appDir": appDir.path, "configsPath": configsURL.path,
                    "settingsPath": settingsURL.path, "logsPath": logsURL.path,
                    "tokenPath": tokenURL.path,
                    "corePath": CoreManager.shared.corePath() ?? ""
                ]))
            case ("POST", "/debug/reload-config"):
                return (200, json(["ok": true]))

            default:
                return (404, err("route not found: \(method) \(path)"))
            }
        } catch {
            return (500, err(error.localizedDescription))
        }
    }

    // ============================================================
    //  Файлы
    // ============================================================

    private func ensureDefaults() {
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            saveSettings(defaultSettings())
        }
        if !FileManager.default.fileExists(atPath: logsURL.path) {
            try? "".write(to: logsURL, atomically: true, encoding: .utf8)
        }
    }

    private func defaultSettings() -> [String: Any] {
        return [
            "peer": "", "vkHashes": "", "vkJsToken": "",
            "workers": DEFAULT_WORKERS, "autoApiWorkers": DEFAULT_AUTO_API_WORKERS,
            "password": "", "obfs": "video", "fingerprint": "firefox",
            "clientIds": "8202606,6287487", "deviceId": getDeviceId(),
            "authMode": "manual", "turnTransport": "udp",
            "turnHost": "", "turnPort": "",
            "captchaMode": "auto", "vkAuthMode": "vkcalls",
            "allowHashRedistribution": false, "validateVkHashes": false,
            "enableSmartTunnel": false, "showCoreLogs": false,
            "shareVpn": false
        ]
    }

    private func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return defaultSettings() }
        return obj
    }

    private func loadSettingsJson() -> String {
        jsonString(from: loadSettings()) ?? "{}"
    }

    private func saveSettings(_ s: [String: Any]) {
        var copy = s
        if let w = copy["workers"] as? Int {
            copy["workers"] = min(max(w, MIN_WORKERS), MAX_WORKERS)
        }
        if let aw = copy["autoApiWorkers"] as? Int {
            copy["autoApiWorkers"] = min(max(aw, MIN_AUTO_API_WORKERS), MAX_AUTO_API_WORKERS)
        }
        if let data = try? JSONSerialization.data(withJSONObject: copy, options: .prettyPrinted) {
            try? data.write(to: settingsURL)
        }
    }

    private func replaceSettings(body: String) -> (Int, String) {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (400, err("bad json")) }
        saveSettings(obj)
        return (200, json(["ok": true]))
    }

    private func patchSettings(body: String) -> (Int, String) {
        guard let data = body.data(using: .utf8),
              let patch = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (400, err("bad json")) }
        var s = loadSettings()
        for (k, v) in patch { s[k] = v }
        saveSettings(s)
        return (200, json(["ok": true]))
    }

    private func getDeviceId() -> String {
        var s = loadSettings()
        var id = s["deviceId"] as? String ?? ""
        if id.isEmpty {
            id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            s["deviceId"] = id
            saveSettings(s)
        }
        return id
    }

    private func updateDeviceId(_ new: String) {
        var s = loadSettings()
        s["deviceId"] = new
        saveSettings(s)
    }

    private func readVkToken() -> String? {
        guard let data = try? Data(contentsOf: tokenURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let t = (obj["Token"] as? String) ?? (obj["token"] as? String) ?? ""
        return t.isEmpty ? nil : t
    }

    private func saveVkToken(_ token: String) {
        let iso = ISO8601DateFormatter().string(from: Date())
        let obj: [String: Any] = ["Token": token, "SavedAt": iso]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? data.write(to: tokenURL)
        }
        log("[VK] token saved to \(tokenURL.path)")
    }

    private func readVkStateJson() -> String {
        let has = readVkToken() != nil
        return json([
            "hasToken": has,
            "fetching": vkLoginInProgress,
            "progress": has ? 100 : (vkLoginInProgress ? 40 : 0),
            "message": has ? "VK token active"
                : (vkLoginInProgress ? vkLoginMessage : "")
        ])
    }

    // ============================================================
    //  Логи
    // ============================================================

    private func currentLogs() -> [String] {
        var out: [String] = []
        stateQueue.sync { out = self.logs }
        return out
    }

    private func log(_ line: String) {
        print("[LaLune] \(line)")
        stateQueue.async(flags: .barrier) {
            self.logs.append(line)
            if self.logs.count > 1000 { self.logs.removeFirst(self.logs.count - 1000) }
        }
        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logsURL) {
                handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
            } else {
                try? data.write(to: logsURL)
            }
        }
        emitEvent(json(["type": "log", "line": line,
                        "ts": Int(Date().timeIntervalSince1970)]))
    }

    private func emitEvent(_ payload: String) {
        stateQueue.sync {
            for (_, send) in self.eventSubscribers { send(payload) }
        }
    }

    private func jsonArrayFromLogs(tail n: Int? = nil) -> String {
        var snap = currentLogs()
        if let n = n, snap.count > n { snap = Array(snap.suffix(n)) }
        if let data = try? JSONSerialization.data(withJSONObject: snap),
           let s = String(data: data, encoding: .utf8) { return s }
        return "[]"
    }

    // ============================================================
    //  Конфиги
    // ============================================================

    private func loadConfigs() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: configsURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr    }

    private func loadConfigsJson() -> String {
        jsonString(from: loadConfigs()) ?? "[]"
    }

    private func saveConfigs(_ arr: [[String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted) {
            try? data.write(to: configsURL)
        }
    }

    private func findConfig(id: Int64) -> [String: Any]? {
        loadConfigs().first {
            ($0["id"] as? Int64) == id || ($0["id"] as? Int) == Int(id)
        }
    }

    private func createConfig(body: String) -> (Int, String) {
        guard let data = body.data(using: .utf8),
              let b = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (400, err("bad json")) }

        var parsed: [String: Any]
        if let link = b["link"] as? String, !link.isEmpty {
            parsed = parseLink(link)
        } else {
            parsed = [
                "protocol": b["protocol"] as? String ?? "CSQTT",
                "peer": b["peer"] as? String ?? "",
                "password": b["password"] as? String ?? "",
                "hashes": b["hashes"] as? String ?? "",
                "name": b["name"] as? String ?? "",
            ]
        }
        let id = Int64(Date().timeIntervalSince1970 * 1000)
        parsed["id"] = id
        parsed["rawLink"] = b["link"] as? String ?? ""
        var arr = loadConfigs()
        arr.append(parsed)
        saveConfigs(arr)
        return (200, json(["id": id]))
    }

    private func readSelectedConfigJson() -> String? {
        guard let data = try? Data(contentsOf: selectedConfigURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeSelectedConfig(_ jsonStr: String) {
        try? jsonStr.write(to: selectedConfigURL, atomically: true, encoding: .utf8)
    }

    private func clearSelectedConfig() {
        try? FileManager.default.removeItem(at: selectedConfigURL)
    }

    private func parseLink(_ link: String) -> [String: Any] {
        var out: [String: Any] = [
            "protocol": "CSQTT", "peer": "", "password": "", "hashes": "", "name": ""
        ]
        guard link.lowercased().hasPrefix("csqtt://") else {
            out["peer"] = link
            return out
        }
        let rest = String(link.dropFirst("csqtt://".count))
        if rest.hasPrefix("connect?") {
            let query = String(rest.dropFirst("connect?".count))
            var host = "", port = "", password = "", hashes = ""
            for kv in query.split(separator: "&") {
                let parts = kv.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let k = String(parts[0]); let v = String(parts[1])
                switch k {
                case "host": host = v
                case "peer": port = v
                case "password": password = v
                case "hashes": hashes = v.replacingOccurrences(of: "+", with: ",")
                default: break
                }
            }
            let peer = "\(host):\(port)"
            out["peer"] = peer; out["password"] = password
            out["hashes"] = hashes; out["name"] = peer
        }
        return out
    }

    // ============================================================
    //  VPN
    // ============================================================

    private func vpnConnect(body: String) -> (Int, String) {
        let settings = loadSettings()
        var peer = settings["peer"] as? String ?? ""
        var password = settings["password"] as? String ?? ""
        var hashes = settings["vkHashes"] as? String ?? ""

        if let data = body.data(using: .utf8),
           let b = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let configId = b["configId"] as? Int64,
           let c = findConfig(id: configId) {
            peer = c["peer"] as? String ?? peer
            password = c["password"] as? String ?? password
            hashes = c["hashes"] as? String ?? hashes
        } else if let sel = readSelectedConfigJson(),
                  let data = sel.data(using: .utf8),
                  let c = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            peer = c["peer"] as? String ?? peer
            password = c["password"] as? String ?? password
            hashes = c["hashes"] as? String ?? hashes
        }

        if peer.isEmpty { return (400, err("no config selected")) }

        CoreManager.shared.writeSharedSettings(
            from: settings, peer: peer, password: password, hashes: hashes
        )

        if CoreManager.shared.corePath() == nil {
            log("[VPN] core not installed, downloading...")
            if !CoreManager.shared.downloadCore() {
                return (500, err("core download failed"))
            }
        }

        // Если включена раздача — запускаем SOCKS5.
        if settings["shareVpn"] as? Bool == true {
            startSocks5()
        }

        log("[VPN] starting NETunnelProviderManager")

        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TUNNEL_BUNDLE_ID
        proto.serverAddress = peer

        manager.protocolConfiguration = proto
        manager.localizedDescription = "LaLune"

        let sem = DispatchSemaphore(value: 0)
        var finalError: Error?

        manager.saveToPreferences { error in
            if let error = error {
                finalError = error
                sem.signal()
                return
            }
            manager.loadFromPreferences { _ in
                do {
                    try manager.connection.startVPNTunnel()
                } catch {
                    finalError = error
                }
                sem.signal()
            }
        }
        sem.wait()

        if let error = finalError {
            log("[VPN] start failed: \(error.localizedDescription)")
            return (500, err("start tunnel failed: \(error.localizedDescription)"))
        }

        vpnConnected = true
        return (200, json(["ok": true, "status": "connecting"]))
    }

    private func vpnDisconnect() -> (Int, String) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            managers?.forEach { $0.connection.stopVPNTunnel() }
        }
        stopSocks5()
        vpnConnected = false
        emitEvent(json(["type": "status", "connected": false,
                        "ts": Int(Date().timeIntervalSince1970)]))
        log("[VPN] disconnect")
        return (200, json(["ok": true]))
    }

    // ============================================================
    //  SOCKS5 (раздача VPN)
    // ============================================================

    private func startSocks5() {
        if socks5Server != nil {
            log("[PROXY] already running")
            return
        }
        let server = Socks5Server(port: 1080) { [weak self] line in
            self?.log(line)
        }
        do {
            try server.start()
            socks5Server = server
        } catch {
            log("[PROXY] failed to start: \(error.localizedDescription)")
        }
    }

    private func stopSocks5() {
        socks5Server?.stop()
        socks5Server = nil
    }

    // ============================================================
    //  VK — свой WKWebView
    // ============================================================

    private func vkLogin() -> (Int, String) {
        if vkLoginInProgress {
            return (200, json(["ok": true, "needsUi": false, "message": "already in progress"]))
        }

        vkLoginInProgress = true
        vkLoginMessage = "Открываю окно авторизации..."
        log("[VK] opening WKWebView")

        DispatchQueue.main.async {
            guard let rootVC = self.topViewController() else {
                self.vkLoginInProgress = false
                self.emitEvent(self.json(["type": "error", "message": "no root view controller"]))
                return
            }

            let vc = VkWebViewController(
                onSuccess: { [weak self] token in
                    guard let self = self else { return }
                    self.vkLoginInProgress = false
                    self.vkLoginMessage = ""
                    self.vkWebVC = nil
                    self.saveVkToken(token)
                    self.log("[VK] token received successfully")
                    self.emitEvent(self.json(["type": "progress",
                                              "kind": "vk_token", "percent": 100]))
                },
                onError: { [weak self] message in
                    guard let self = self else { return }
                    self.vkLoginInProgress = false
                    self.vkLoginMessage = message
                    self.vkWebVC = nil
                    self.log("[VK] error: \(message)")
                    self.emitEvent(self.json(["type": "error", "message": "VK: \(message)"]))
                }
            )

            self.vkWebVC = vc
            rootVC.present(vc, animated: true)
        }

        return (200, json(["ok": true, "needsUi": false]))
    }

    private func topViewController() -> UIViewController? {
        var vc = window?.rootViewController
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    // ============================================================
    //  VK Calls
    // ============================================================

    private func vkCallsStart(body: String) -> (Int, String) {
        guard let token = readVkToken() else { return (400, err("no VK token")) }
        guard let data = body.data(using: .utf8),
              let b = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (400, err("bad json")) }

        let s = loadSettings()
        let workers = b["workers"] as? Int ?? s["workers"] as? Int ?? DEFAULT_WORKERS
        let aw = b["autoApiWorkers"] as? Int
            ?? s["autoApiWorkers"] as? Int ?? DEFAULT_AUTO_API_WORKERS
        let count = callCountForWorkers(workers: workers, aw: aw)

        var hashes: [String] = []
        var callIds: [String] = []

        for slot in 0..<count {
            if slot > 0 { Thread.sleep(forTimeInterval: count <= 4 ? 0.08 : 0.202) }
            let (cid, hash, errCode) = startVkCall(token: token)
            if !hash.isEmpty {
                hashes.append(hash); callIds.append(cid); activeCallIds.append(cid)
            } else if [4, 5, 27, 28].contains(errCode) {
                return (401, err("VK token invalid"))
            }
        }
        if hashes.isEmpty { return (500, err("no calls created")) }
        return (200, json(["hashes": hashes, "callIds": callIds]))
    }

    private func callCountForWorkers(workers: Int, aw: Int) -> Int {
        let aw2 = aw <= 0 ? DEFAULT_AUTO_API_WORKERS : aw
        let w2 = workers <= 0 ? DEFAULT_WORKERS : workers
        let count = Int(ceil(Double(w2) / Double(aw2)))
        return min(max(count, 1), 6)
    }

    private func startVkCall(token: String) -> (String, String, Int) {
        guard let url = URL(string: VK_API_BASE + "calls.start") else { return ("", "", -1) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.httpBody = "v=\(VK_API_VERSION)".data(using: .utf8)

        let sem = DispatchSemaphore(value: 0)
        var result: (String, String, Int) = ("", "", -1)

        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if let e = j["error"] as? [String: Any] {
                result = ("", "", e["error_code"] as? Int ?? 0)
                return
            }
            guard let r = j["response"] as? [String: Any] else { return }
            let callId = r["call_id"] as? String ?? ""
            let okLink = r["ok_join_link"] as? String ?? ""
            let joinLink = r["join_link"] as? String ?? ""
            let hash = !okLink.isEmpty ? okLink
                : (joinLink.components(separatedBy: "/").last ?? "")
            result = (callId, hash, 0)
        }.resume()
        sem.wait()
        return result
    }

    // ============================================================
    //  Helpers
    // ============================================================

    private func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func jsonString(from obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func err(_ message: String) -> String {
        json(["error": message])
    }

    private func queryValue(_ query: String, _ key: String) -> String? {
        for kv in query.split(separator: "&") {
            let parts = kv.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0] == key { return String(parts[1]) }
        }
        return nil
    }
}
