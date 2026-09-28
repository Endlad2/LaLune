import Foundation
import Flutter
import NetworkExtension
import SQLite3

/// Обработчик MethodChannel "lalune/api" для iOS.
/// Тот же контракт, что и на Android / Desktop FFI.
final class LaluneApiBridge {

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "lalune/api", binaryMessenger: messenger)
        let instance = LaluneApiBridge()
        channel.setMethodCallHandler { call, result in
            instance.handle(call: call, result: result)
        }
    }

    private let appDir: URL = {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }()
    private let appGroup = "group.com.lalune"
    private var db: OpaquePointer?
    private var isConnected = false
    private var vkLoginInProgress = false

    private init() {
        let dbPath = appDir.appendingPathComponent("configs.db").path
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            let create = """
            CREATE TABLE IF NOT EXISTS configs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                protocol TEXT NOT NULL DEFAULT 'CSQTT',
                peer TEXT NOT NULL DEFAULT '',
                password TEXT NOT NULL DEFAULT '',
                hashes TEXT NOT NULL DEFAULT '',
                name TEXT DEFAULT '',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
            sqlite3_exec(db, create, nil, nil, nil)
        }
    }

    // MARK: - Dispatch

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "GetConfigsJson":          result(getConfigsJson())
        case "SaveConfig":
            let args = call.arguments as? [String: Any] ?? [:]
            result(saveConfig(args["link"] as? String ?? "",
                              protocol: args["protocol"] as? String ?? "CSQTT"))
        case "DeleteConfig":
            let args = call.arguments as? [String: Any] ?? [:]
            result(deleteConfig((args["id"] as? NSNumber)?.int64Value ?? 0))
        case "GetSettingsJson":         result(getSettingsJson())
        case "SaveSettings":
            let args = call.arguments as? [String: Any] ?? [:]
            result(saveSettings(args["json"] as? String ?? "{}"))
        case "GetLogsJson":             result(getLogsJson())
        case "ClearLogs":               clearLogs(); result(true)
        case "GetStatusJson":           result("{\"connected\":\(isConnected)}")

        case "Connect":
            let args = call.arguments as? [String: Any] ?? [:]
            result(connect((args["id"] as? NSNumber)?.int64Value ?? 0))
        case "Disconnect":              result(disconnect())

        case "CheckCoreUpdate":         result("{\"update\":false,\"version\":\"\"}")
        case "UpdateCoreAndWait":       result(true)
        case "CheckLaLuneUpdate":       result("{\"update\":false,\"version\":\"0.6.0\"}")
        case "OpenLaLuneReleases":
            if let url = URL(string: "https://github.com/Endlad2/LaLune/releases/latest") {
                UIApplication.shared.open(url)
                result(true)
            } else { result(false) }

        case "GetVKTokenState":         result(computeVkTokenState())
        case "ValidateVKToken":         result(computeVkTokenState())
        case "VkLogin":                 result(vkLogin())
        case "DeleteVKToken":           deleteVkToken(); result(true)
        case "RunVkAutoApiCalls":       result("{\"error\":\"not supported\"}")
        case "PollAutoApiResult":       result("{\"pending\":false}")
        case "FinishVkCalls":           result(false)

        case "GetDeviceId":             result(getDeviceId())
        case "RegenerateDeviceId":      result(regenerateDeviceId())

        case "SetSelectedConfigJson":   result(true)
        case "GetSelectedConfigJson":   result("{}")

        case "IsCoreDownloading":       result(false)
        case "DeployProtocol":          result(false)
        case "DeployLog":               result("")
        case "IsDeploying":             result(false)

        default:                        result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Configs

    private func getConfigsJson() -> String {
        var configs: [[String: Any]] = []
        let query = "SELECT id, protocol, peer, password, hashes, name FROM configs ORDER BY id DESC"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                configs.append([
                    "id": sqlite3_column_int64(stmt, 0),
                    "protocol": String(cString: sqlite3_column_text(stmt, 1)),
                    "peer": String(cString: sqlite3_column_text(stmt, 2)),
                    "password": String(cString: sqlite3_column_text(stmt, 3)),
                    "hashes": String(cString: sqlite3_column_text(stmt, 4)),
                    "name": String(cString: sqlite3_column_text(stmt, 5)),
                ])
            }
        }
        sqlite3_finalize(stmt)
        if let data = try? JSONSerialization.data(withJSONObject: configs),
           let json = String(data: data, encoding: .utf8) { return json }
        return "[]"
    }

    private func saveConfig(_ link: String, protocol: String) -> Bool {
        let c = parseCsqttLink(link)
        let insert = "INSERT INTO configs (protocol, peer, password, hashes, name) VALUES (?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (protocol as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (c.peer as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (c.password as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (c.hashes as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (c.peer as NSString).utf8String, -1, nil)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    private func deleteConfig(_ id: Int64) -> Bool {
        let del = "DELETE FROM configs WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, del, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(stmt, 1, id)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    // MARK: - Settings

    private func getSettingsJson() -> String {
        let path = appDir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: path),
           let json = String(data: data, encoding: .utf8) { return json }
        // default
        let defaults: [String: Any] = [
            "workers": 9, "autoApiWorkers": 9,
            "obfs": "audio", "fingerprint": "chrome",
            "clientIds": "8202606,6287487",
            "vkAuthMode": "vkcalls", "captchaMode": "auto",
            "authMode": "manual", "turnTransport": "udp",
            "deviceId": newDeviceId(),
            "enableSmartTunnel": false,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: defaults),
           let json = String(data: data, encoding: .utf8) {
            try? json.write(to: path, atomically: true, encoding: .utf8)
            return json
        }
        return "{}"
    }

    private func saveSettings(_ json: String) -> Bool {
        let path = appDir.appendingPathComponent("settings.json")
        do {
            try json.write(to: path, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    // MARK: - Logs

    private func getLogsJson() -> String {
        var allLines: [String] = []
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let logURL = container.appendingPathComponent("tunnel.log")
            if let s = try? String(contentsOf: logURL, encoding: .utf8) {
                allLines.append(contentsOf: s.split(separator: "\n").map(String.init))
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: allLines),
           let json = String(data: data, encoding: .utf8) { return json }
        return "[]"
    }

    private func clearLogs() {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let logURL = container.appendingPathComponent("tunnel.log")
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - VK

    private func computeVkTokenState() -> String {
        let tokenPath = appDir.appendingPathComponent("token.json")
        var has = false
        if let data = try? Data(contentsOf: tokenPath),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = j["Token"] as? String, !t.isEmpty { has = true }
        let dict: [String: Any] = [
            "hasToken": has, "fetcherOk": true,
            "fetching": vkLoginInProgress,
            "message": has ? "Токен ВК активен" : "",
            "progress": has ? 100 : 0,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }

    private func vkLogin() -> Bool {
        // iOS: требует WebView-модалку. В этой итерации — заглушка.
        return false
    }

    private func deleteVkToken() {
        let path = appDir.appendingPathComponent("token.json")
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Device ID

    private func getDeviceId() -> String {
        let prefs = UserDefaults.standard
        if let id = prefs.string(forKey: "deviceId"), !id.isEmpty { return id }
        let id = newDeviceId()
        prefs.set(id, forKey: "deviceId")
        return id
    }

    private func regenerateDeviceId() -> String {
        let id = newDeviceId()
        UserDefaults.standard.set(id, forKey: "deviceId")
        return id
    }

    private func newDeviceId() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // MARK: - VPN

    private func connect(_ id: Int64) -> Bool {
        // Реализуется через NETunnelProviderManager, см. ViewController.swift
        // (там сохранены конфиг и старт туннеля).
        return true
    }

    private func disconnect() -> Bool {
        let mgr = NETunnelProviderManager()
        mgr.connection.stopVPNTunnel()
        isConnected = false
        return true
    }

    // MARK: - Parser

    private func parseCsqttLink(_ link: String) -> (peer: String, password: String, hashes: String) {
        var peer = link, password = "", hashes = ""
        guard link.hasPrefix("csqtt://") else { return (peer, password, hashes) }
        if let url = URL(string: link),
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if comps.host == "connect" {
                var host = "", port = ""
                for qi in comps.queryItems ?? [] {
                    switch qi.name {
                    case "host": host = qi.value ?? ""
                    case "peer": port = qi.value ?? ""
                    case "password": password = qi.value ?? ""
                    case "hashes": hashes = (qi.value ?? "").replacingOccurrences(of: "+", with: ",")
                    default: break
                    }
                }
                peer = "\(host):\(port)"
            } else {
                let host = comps.host ?? ""
                let port = comps.port ?? 46000
                password = comps.user ?? ""
                peer = "\(host):\(port)"
            }
        }
        return (peer, password, hashes)
    }
}
