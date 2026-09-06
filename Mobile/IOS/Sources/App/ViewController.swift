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
        // Пробуем сначала app-ios.html, потом app.html
        if let htmlPath = Bundle.main.path(forResource: "app", ofType: "html") {
            let url = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // Фолбэк — загружаем пустую страницу с сообщением
            let html = "<html><body style='background:#0a0e2a;color:white;font-family:monospace;display:flex;align-items:center;justify-content:center;height:100vh;'><div>HTML not found</div></body></html>"
            webView.loadHTMLString(html, baseURL: nil)
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
        
        if let data = try? JSONSerialization.data(withJSON
