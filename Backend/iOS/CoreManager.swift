// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Ядро CSQTT: скачивание + парсинг логов (TUNCONF, статистика) +
// запись общих настроек для Tunnel Extension.
//
// Используется основным приложением (Backend.swift) — не extension'ом.

import Foundation

@available(iOS 17.0, *)
final class CoreManager {

    static let shared = CoreManager()

    private let APP_GROUP = "group.com.lalune"

    private let LATEST_URL =
        "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
    private let CORE_URL_TEMPLATE =
        "https://github.com/Endlad2/csqtt-core/releases/download/%@/%@"
    private let PROXY_URL = "http://31.77.148.203:8855/?url="
    private let UA_BROWSER =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private let UA_CURL = "curl/7.68.0"

    // Регулярки для парсинга логов ядра
    private let tunconfRe = try! NSRegularExpression(
        pattern: "TUNCONF:([\\d.]+):([\\d.,]+)"
    )
    private let tunconfAltRe = try! NSRegularExpression(
        pattern: "Tunnel IP:\\s*([\\d.]+)(?:/\\d+)?\\s*\\|\\s*DNS:\\s*([\\d.,]+)"
    )
    private let statsRe = try! NSRegularExpression(
        pattern: "\\[СТАТИСТИКА\\]\\s*Активных:\\s*(\\d+)\\s*\\|\\s*Трафи[кф]+:\\s*([\\d.]+)"
    )

    private var appDir: URL {
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP) {
            let dir = container.appendingPathComponent("la-lune", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            return dir
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("la-lune", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var latestURL: URL { appDir.appendingPathComponent("LATEST") }
    private var coreDir: URL { appDir.appendingPathComponent("core", isDirectory: true) }

    // ============================================================
    //  Чтение локальной версии
    // ============================================================

    func readLatest() -> String {
        (try? String(contentsOf: latestURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func corePath() -> String? {
        let f = coreDir.appendingPathComponent("csqtt-core")
        return FileManager.default.fileExists(atPath: f.path) ? f.path : nil
    }

    // ============================================================
    //  Скачивание (трёхуровневый fallback)
    // ============================================================

    func fetchLatestVersion() -> String? {
        for level in 1...3 {
            let urlStr = level == 1
                ? LATEST_URL
                : PROXY_URL + (LATEST_URL.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed) ?? "")
            guard let url = URL(string: urlStr) else { continue }

            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.setValue(level == 3 ? UA_CURL : UA_BROWSER,
                         forHTTPHeaderField: "User-Agent")

            let sem = DispatchSemaphore(value: 0)
            var result: String?
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { sem.signal() }
                guard let data = data,
                      let s = String(data: data, encoding: .utf8) else { return }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty &&
                    !trimmed.contains("Server error") &&
                    !trimmed.contains("No connection adapters") &&
                    !trimmed.contains("curl error") {
                    result = trimmed
                }
            }.resume()
            sem.wait()
            if let r = result { return r }
        }
        return nil
    }

    func downloadCore() -> Bool {
        guard let version = fetchLatestVersion() else { return false }
        let filename = "csqtt-core"
        let base = String(format: CORE_URL_TEMPLATE, version, filename)

        for level in 1...3 {
            let urlStr = level == 1
                ? base
                : PROXY_URL + (base.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed) ?? "")
            guard let url = URL(string: urlStr) else { continue }

            var req = URLRequest(url: url)
            req.timeoutInterval = 60
            req.setValue(level == 3 ? UA_CURL : UA_BROWSER,
                         forHTTPHeaderField: "User-Agent")

            let sem = DispatchSemaphore(value: 0)
            var success = false
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { sem.signal() }
                guard let data = data, data.count > 1024 else { return }
                try? FileManager.default.createDirectory(
                    at: self.coreDir, withIntermediateDirectories: true)
                let dest = self.coreDir.appendingPathComponent(filename)
                try? data.write(to: dest)
                try? version.write(to: self.latestURL, atomically: true, encoding: .utf8)
                success = true
            }.resume()
            sem.wait()
            if success { return true }
        }
        return false
    }

    // ============================================================
    //  Парсинг логов
    // ============================================================

    func parseTunconf(_ line: String) -> (String, String)? {
        for re in [tunconfRe, tunconfAltRe] {
            let range = NSRange(line.startIndex..., in: line)
            if let m = re.firstMatch(in: line, range: range), m.numberOfRanges >= 3,
               let r1 = Range(m.range(at: 1), in: line),
               let r2 = Range(m.range(at: 2), in: line) {
                return (String(line[r1]), String(line[r2]))
            }
        }
        return nil
    }

    func parseStats(_ line: String) -> (Int, Double)? {
        let range = NSRange(line.startIndex..., in: line)
        if let m = statsRe.firstMatch(in: line, range: range), m.numberOfRanges >= 3,
           let r1 = Range(m.range(at: 1), in: line),
           let r2 = Range(m.range(at: 2), in: line) {
            let active = Int(line[r1]) ?? 0
            let traffic = Double(line[r2]) ?? 0.0
            return (active, traffic)
        }
        return nil
    }

    // ============================================================
    //  Запись настроек для Tunnel Extension
    // ============================================================

    /// Записывает все нужные параметры в UserDefaults App Group,
    /// чтобы PacketTunnelProvider их прочитал при startTunnel().
    func writeSharedSettings(from settingsJson: [String: Any],
                             peer: String,
                             password: String,
                             hashes: String) {
        let shared = UserDefaults(suiteName: APP_GROUP)
        shared?.set(peer, forKey: "peer")
        shared?.set(password, forKey: "password")
        shared?.set(hashes, forKey: "hashes")
        shared?.set(settingsJson["workers"] as? Int ?? 9, forKey: "workers")
        shared?.set(settingsJson["obfs"] as? String ?? "video", forKey: "obfs")
        shared?.set(settingsJson["fingerprint"] as? String ?? "firefox",
                    forKey: "fingerprint")
        shared?.set(settingsJson["clientIds"] as? String ?? "8202606,6287487",
                    forKey: "clientIds")
        shared?.set(settingsJson["vkAuthMode"] as? String ?? "vkcalls",
                    forKey: "vkAuthMode")
        shared?.set(settingsJson["captchaMode"] as? String ?? "auto",
                    forKey: "captchaMode")
        shared?.set(settingsJson["deviceId"] as? String ?? "", forKey: "deviceId")
        shared?.synchronize()
    }
}
