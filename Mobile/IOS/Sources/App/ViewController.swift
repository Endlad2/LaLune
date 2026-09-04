import UIKit
import WebKit
import NetworkExtension
import SQLite3

class ViewController: UIViewController, WKScriptMessageHandler {
    var webView: WKWebView!
    var isConnected = false
    var db: OpaquePointer?
    
    let appDir: String = {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].path
    }()
    
    let appGroup = "group.com.lalune"
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        initDatabase()
        loadSettings()
        
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "lalune")
        config.userContentController = userContentController
        
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
        
        loadHTML()
    }
    
    func loadHTML() {
        if let htmlPath = Bundle.main.path(forResource: "app", ofType: "html") {
            let url = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
    
    // ============ WKScriptMessageHandler ============
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "lalune",
              let body = message.body as? [String: Any],
              let method = body["method"] as? String,
              let callbackId = body["callbackId"] as? String else { return }
        
        DispatchQueue.global().async {
            let result: String
            
            switch method {
            case "getConfigs":
                result = self.getConfigsJson()
            case "getSettings":
                result = self.getSettingsJson()
            case "getLogs":
                result = self.getLogsJson()
            case "getStatus":
                result = "{\"connected\":\(self.isConnected)}"
            case "saveConfig":
                let link = body["link"] as? String ?? ""
                result = "\(self.saveConfig(link))"
            case "deleteConfig":
                let id = body["id"] as? Int64 ?? 0
                result = "\(self.deleteConfig(id))"
            case "saveSettings":
                let settingsJson = body["settings"] as? String ?? ""
                result = "\(self.saveSettings(settingsJson))"
            case "connect":
                let configId = body["configId"] as? Int64 ?? 0
                result = "\(self.connect(configId))"
            case "disconnect":
                result = "\(self.disconnect())"
            case "clearLogs":
                result = "\(self.clearLogs())"
            case "updateCore":
                result = "\(self.updateCore())"
            case "checkUpdate":
                result = self.checkUpdate()
            case "updateCoreAndWait":
                result = "\(self.updateCoreAndWait())"
            default:
                result = "false"
            }
            
            self.sendCallback(callbackId, result: result)
        }
    }
    
    // ============ Отправка в JS ============
    
    func sendCallback(_ callbackId: String, result: String) {
        DispatchQueue.main.async {
            let escaped = result
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            
            let js = "window._iosCallback('\(callbackId)', '\(escaped)')"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    func sendLog(_ message: String) {
        DispatchQueue.main.async {
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            
            let js = "window._iosLog('\(escaped)')"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    func sendStatus(_ connected: Bool) {
        DispatchQueue.main.async {
            let js = "window._iosStatus(\(connected))"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    // ============ БД ============
    
    func initDatabase() {
        let dbPath = (appDir as NSString).appendingPathComponent("configs.db")
        
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            let createTable = """
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
            sqlite3_exec(db, createTable, nil, nil, nil)
        }
    }
    
    func getConfigsJson() -> String {
        var configs: [[String: Any]] = []
        let query = "SELECT id, protocol, peer, password, hashes, name FROM configs ORDER BY id DESC"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let proto = String(cString: sqlite3_column_text(statement, 1))
                let peer = String(cString: sqlite3_column_text(statement, 2))
                let password = String(cString: sqlite3_column_text(statement, 3))
                let hashes = String(cString: sqlite3_column_text(statement, 4))
                let name = String(cString: sqlite3_column_text(statement, 5))
                
                configs.append([
                    "id": id,
                    "protocol": proto,
                    "peer": peer,
                    "password": password,
                    "hashes": hashes,
                    "name": name
                ])
            }
        }
        sqlite3_finalize(statement)
        
        if let data = try? JSONSerialization.data(withJSONObject: configs, options: []),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "[]"
    }
    
    func saveConfig(_ link: String) -> Bool {
        let config = parseCsqttLink(link)
        
        let insert = "INSERT INTO configs (protocol, peer, password, hashes, name) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, "CSQTT", -1, nil)
            sqlite3_bind_text(statement, 2, (config.peer as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (config.password as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (config.hashes as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 5, (config.name as NSString).utf8String, -1, nil)
            
            let result = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            return result
        }
        
        return false
    }
    
    func deleteConfig(_ id: Int64) -> Bool {
        let delete = "DELETE FROM configs WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, delete, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            let result = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            return result
        }
        
        return false
    }
    
    // ============ Настройки ============
    
    func loadSettings() {
        let settingsPath = (appDir as NSString).appendingPathComponent("settings.json")
        
        if !FileManager.default.fileExists(atPath: settingsPath) {
            let defaultSettings: [String: Any] = [
                "workersPerHash": 9,
                "obfs": "video",
                "fingerprint": "firefox",
                "clientIds": "8202606,6287487",
                "vkAuthMode": "vkcalls",
                "captchaMode": "auto",
                "deviceId": String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
            ]
            
            if let data = try? JSONSerialization.data(withJSONObject: defaultSettings, options: .prettyPrinted) {
                try? data.write(to: URL(fileURLWithPath: settingsPath))
            }
        }
    }
    
    func getSettingsJson() -> String {
        let settingsPath = (appDir as NSString).appendingPathComponent("settings.json")
        
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }
    
    func saveSettings(_ settingsJson: String) -> Bool {
        let settingsPath = (appDir as NSString).appendingPathComponent("settings.json")
        
        do {
            try settingsJson.write(toFile: settingsPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
    
    // ============ Логи ============
    
    func getLogsJson() -> String {
        let logsPath = (appDir as NSString).appendingPathComponent("logs.txt")
        
        if let content = try? String(contentsOfFile: logsPath, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            if let data = try? JSONSerialization.data(withJSONObject: lines, options: []),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
        }
        return "[]"
    }
    
    func clearLogs() -> Bool {
        let logsPath = (appDir as NSString).appendingPathComponent("logs.txt")
        try? "".write(toFile: logsPath, atomically: true, encoding: .utf8)
        return true
    }
    
    // ============ VPN ============
    
    func connect(_ configId: Int64) -> Bool {
        // Получаем конфиг из БД
        let config = getConfigById(configId)
        guard !config.peer.isEmpty else { return false }
        
        // Сохраняем конфиг в App Group для Extension
        let sharedDefaults = UserDefaults(suiteName: appGroup)
        sharedDefaults?.set(config.peer, forKey: "peer")
        sharedDefaults?.set(config.password, forKey: "password")
        sharedDefaults?.set(config.hashes, forKey: "hashes")
        sharedDefaults?.synchronize()
        
        // Запускаем VPN
        let tunnelManager = NETunnelProviderManager()
        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = "com.lalune.tunnel"
        protocolConfig.serverAddress = config.peer
        
        tunnelManager.protocolConfiguration = protocolConfig
        tunnelManager.localizedDescription = "LaLune"
        
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        
        tunnelManager.saveToPreferences { error in
            if error == nil {
                try? tunnelManager.connection.startVPNTunnel()
                success = true
                self.isConnected = true
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        return success
    }
    
    func disconnect() -> Bool {
        let tunnelManager = NETunnelProviderManager()
        tunnelManager.connection.stopVPNTunnel()
        isConnected = false
        sendStatus(false)
        return true
    }
    
    func getConfigById(_ id: Int64) -> (peer: String, password: String, hashes: String) {
        let query = "SELECT peer, password, hashes FROM configs WHERE id = ?"
        var statement: OpaquePointer?
        var result: (String, String, String) = ("", "", "")
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            
            if sqlite3_step(statement) == SQLITE_ROW {
                let peer = String(cString: sqlite3_column_text(statement, 0))
                let password = String(cString: sqlite3_column_text(statement, 1))
                let hashes = String(cString: sqlite3_column_text(statement, 2))
                result = (peer, password, hashes)
            }
        }
        sqlite3_finalize(statement)
        return result
    }
    
    // ============ Обновления ============
    
    func updateCore() -> Bool {
        sendLog("[UPDATE] Проверка обновлений...")
        return true
    }
    
    func checkUpdate() -> String {
        return "{\"update\":false,\"version\":\"\"}"
    }
    
    func updateCoreAndWait() -> Bool {
        sendLog("[UPDATE] Обновление...")
        return true
    }
    
    // ============ Парсер csqtt:// ============
    
    func parseCsqttLink(_ link: String) -> (peer: String, password: String, hashes: String, name: String) {
        var result = ("", "", "", "Config")
        
        guard link.hasPrefix("csqtt://") else {
            result.0 = link
            return result
        }
        
        if let url = URL(string: link),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            
            if components.host == "connect" {
                var host = ""
                var port = ""
                var password = ""
                var hashes = ""
                
                for param in components.queryItems ?? [] {
                    switch param.name {
                    case "host": host = param.value ?? ""
                    case "peer": port = param.value ?? ""
                    case "password": password = param.value ?? ""
                    case "hashes": hashes = (param.value ?? "").replacingOccurrences(of: "+", with: ",")
                    default: break
                    }
                }
                
                result.0 = "\(host):\(port)"
                result.1 = password
                result.2 = hashes
                result.3 = result.0
            } else {
                let host = components.host ?? ""
                let port = components.port ?? 46000
                let password = components.user ?? ""
                
                result.0 = "\(host):\(port)"
                result.1 = password
                result.3 = result.0
            }
        }
        
        return result
    }
}
