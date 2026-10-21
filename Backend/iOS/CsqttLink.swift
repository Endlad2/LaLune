// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Swift-обёртка над Core/csqtt-link (staticlib).
//
// Требует: libcsqtt_link.a в LIBRARY_SEARCH_PATHS + csqtt_link_bridge.h
// в bridging-header.

import Foundation

@available(iOS 17.0, *)
enum CsqttLink {
    struct Info {
        let host: String
        let port: Int
        let password: String
        let hashes: [String]
        let vkAccessToken: String
    }

    static func parse(_ link: String) -> Info? {
        guard let json = callNative(link, decode: false) else { return nil }
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let host = obj["host"] as? String ?? ""
        let port = obj["port"] as? Int ?? 0
        let password = obj["password"] as? String ?? ""
        let hashes = obj["hashes"] as? [String] ?? []
        let token = obj["vk_access_token"] as? String ?? ""

        guard !host.isEmpty, port > 0 else { return nil }
        return Info(host: host, port: port, password: password,
                    hashes: hashes, vkAccessToken: token)
    }

    /// Возвращает `csqtt://connect?...` или nil.
    static func decode(_ link: String) -> String? {
        callNative(link, decode: true)
    }

    /// Парсит json-строку, возвращает словарь для использования в Backend.swift.
    static func parseToJson(_ link: String) -> String? {
        callNative(link, decode: false)
    }

    private static func callNative(_ link: String, decode: Bool) -> String? {
        guard let cstr = link.cString(using: .utf8) else { return nil }
        let result: UnsafeMutablePointer<CChar>?
        if decode {
            result = csqtt_link_decode(cstr)
        } else {
            result = csqtt_link_parse(cstr)
        }
        guard let ptr = result else { return nil }
        defer { csqtt_link_free(ptr) }
        return String(cString: ptr)
    }
}
