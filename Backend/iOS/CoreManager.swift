// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Ядро: CSQTT + PaperFlux (iOS). Скачивание + парсинг логов +
// запись общих настроек для Tunnel Extension.

import Foundation

@available(iOS 17.0, *)
final class CoreManager {

    static let shared = CoreManager()

    private let APP_GROUP = "group.com.lalune"

    private let LATEST_CSQTT_URL =
        "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
    private let LATEST_PAPERFLUX_URL =
        "https://raw.githubusercontent.com/Endlad2/PaperFlux-core/refs/heads/main/LATEST"

    private let CSQTT_URL_TEMPLATE =
        "https://github.com/Endlad2/csqtt-core/releases/download/%@/%@"
    private let PAPERFLUX_URL =
        "https://github.com/Endlad2/PaperFlux-core/releases/latest/download/paperflux-ios.zip"

    private let PROXY_URL = "http://31.77.148.203:8855/?url="
    private let UA_BROWSER =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private let UA_CURL = "curl/7.68.0"

    private let tunconfRe = try! NSRegularExpression(pattern: "TUNCONF:([\\d.]+):([\\d.,]+)")
    private let tunconfAltRe = try! NSRegularExpression(pattern: "Tunnel IP:\\s*([\\d.]+)(?:/\\d+)?\\s*\\|\\s*DNS:\\s*([\\d.,]+)")
    private let statsRe = try! NSRegularExpression(pattern: "\\[СТАТИСТИКА\\]\\s*Активных:\\s*(\\d+)\\s*\\|\\s*Трафи[кф]+:\\s*([\\d.]+)")

    private var appDir: URL {
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP) {
            let dir = container.appendingPathComponent("la-lune", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("la-lune", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var coreDir: URL { appDir.appendingPathComponent("core", isDirectory: true) }

    // MARK: - Чтение локальной версии

    func readLatest(protocol proto: String = "CSQTT") -> String {
        let f = latestFile(protocol: proto)
        return (try? String(contentsOf: f, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func latestFile(protocol proto: String) -> URL {
        let name = proto.lowercased() == "paperflux" ? "LATEST.PaperFlux" : "LATEST.Csqtt"
        return appDir.appendingPathComponent(name)
    }

    func corePath(protocol proto: String = "CSQTT") -> String? {
        let filename = proto.lowercased() == "paperflux" ? "paperflux-core" : "csqtt-core"
        let f = coreDir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: f.path) ? f.path : nil
    }

    // MARK: - LATEST

    func fetchLatestVersion(protocol proto: String = "CSQTT") -> String? {
        let baseURL = proto.lowercased() == "paperflux" ? LATEST_PAPERFLUX_URL : LATEST_CSQTT_URL
        for level in 1...3 {
            let urlStr = level == 1
                ? baseURL
                : PROXY_URL + (baseURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.setValue(level == 3 ? UA_CURL : UA_BROWSER, forHTTPHeaderField: "User-Agent")

            let sem = DispatchSemaphore(value: 0)
            var result: String?
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { sem.signal() }
                guard let data = data, let s = String(data: data, encoding: .utf8) else { return }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty
                    && !trimmed.contains("Server error")
                    && !trimmed.contains("No connection adapters")
                    && !trimmed.contains("curl error") {
                    result = trimmed
                }
            }.resume()
            sem.wait()
            if let r = result { return r }
        }
        return nil
    }

    // MARK: - Download

    func downloadCore(protocol proto: String = "CSQTT") -> Bool {
        return proto.lowercased() == "paperflux" ? downloadPaperFlux() : downloadCsqtt()
    }

    private func downloadCsqtt() -> Bool {
        guard let version = fetchLatestVersion(protocol: "CSQTT") else { return false }
        let filename = "csqtt-core"
        let base = String(format: CSQTT_URL_TEMPLATE, version, filename)
        return downloadFrom(baseURL: base, destName: filename, latestName: "LATEST.Csqtt", latestValue: version)
    }

    private func downloadPaperFlux() -> Bool {
        // paperflux-ios.zip содержит liboflux.a + liboflux.h.
        // Мы кладём .a в Core/ — как статическую библиотеку. На iOS ядро
        // линкуется в tunnel-extension, а не запускается как процесс.
        for level in 1...3 {
            let urlStr = level == 1
                ? PAPERFLUX_URL
                : PROXY_URL + (PAPERFLUX_URL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 120
            req.setValue(level == 3 ? UA_CURL : UA_BROWSER, forHTTPHeaderField: "User-Agent")

            let sem = DispatchSemaphore(value: 0)
            var success = false
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { sem.signal() }
                guard let data = data, data.count > 1024 else { return }
                try? FileManager.default.createDirectory(at: self.coreDir, withIntermediateDirectories: true)
                // Сохраняем zip; Tunnel Extension сам распакует нужный .a.
                let zipDest = self.coreDir.appendingPathComponent("paperflux-ios.zip")
                try? data.write(to: zipDest)
                try? "latest".write(to: self.latestFile(protocol: "PaperFlux"),
                                     atomically: true, encoding: .utf8)
                success = true
            }.resume()
            sem.wait()
            if success { return true }
        }
        return false
    }

    private func downloadFrom(baseURL: String, destName: String, latestName: String, latestValue: String) -> Bool {
        for level in 1...3 {
            let urlStr = level == 1
                ? baseURL
                : PROXY_URL + (baseURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 60
            req.setValue(level == 3 ? UA_CURL : UA_BROWSER, forHTTPHeaderField: "User-Agent")

            let sem = DispatchSemaphore(value: 0)
            var success = false
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { sem.signal() }
                guard let data = data, data.count > 1024 else { return }
                try? FileManager.default.createDirectory(at: self.coreDir, withIntermediateDirectories: true)
                let dest = self.coreDir.appendingPathComponent(destName)
                try? data.write(to: dest)
                try? latestValue.write(to: self.appDir.appendingPathComponent(latestName),
                                       atomically: true, encoding: .utf8)
                success = true
            }.resume()
            sem.wait()
            if success { return true }
        }
        return false
    }

    // MARK: - Парсинг логов

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
            return (Int(line[r1]) ?? 0, Double(line[r2]) ?? 0.0)
        }
        return nil
    }

    // MARK: - Shared settings для Tunnel

    func writeSharedSettings(
        from settingsJson: [String: Any],
        protocol proto: String,
        peer: String,
        password: String,
        hashes: String,
        paperfluxArgs: [String] = []
    ) {
        let shared = UserDefaults(suiteName: APP_GROUP)
        shared?.set(proto, forKey: "protocol")
        shared?.set(peer, forKey: "peer")
        shared?.set(password, forKey: "password")
        shared?.set(hashes, forKey: "hashes")
        shared?.set(settingsJson["workers"] as? Int ?? 9, forKey: "workers")

        // CSQTT-поля
        shared?.set(settingsJson["obfs"] as? String ?? "video", forKey: "obfs")
        shared?.set(settingsJson["fingerprint"] as? String ?? "firefox", forKey: "fingerprint")
        shared?.set(settingsJson["clientIds"] as? String ?? "8202606,6287487", forKey: "clientIds")
        shared?.set(settingsJson["vkAuthMode"] as? String ?? "vkcalls", forKey: "vkAuthMode")
        shared?.set(settingsJson["captchaMode"] as? String ?? "auto", forKey: "captchaMode")

        // PaperFlux-поля
        shared?.set(paperfluxArgs, forKey: "paperfluxArgs")
        shared?.set(settingsJson["pfTransport"] as? String ?? "yandex", forKey: "pfTransport")
        shared?.set(settingsJson["pfMode"] as? String ?? "proxy", forKey: "pfMode")
        shared?.set(settingsJson["pfSocks5"] as? String ?? "127.0.0.1:1080", forKey: "pfSocks5")
        shared?.set(settingsJson["pfClientIp"] as? String ?? "10.10.10.2", forKey: "pfClientIp")

        shared?.set(settingsJson["deviceId"] as? String ?? "", forKey: "deviceId")
        shared?.synchronize()
    }
}
