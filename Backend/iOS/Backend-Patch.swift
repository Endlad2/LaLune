// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Патч для Backend.swift — три изменения:
//
// 1. run() теперь бросает исключение (throws), а не глотает его.
// 2. HttpServer.start() теперь тоже throws.
// 3. attach(window:) сохраняет window в свойство, но НЕ требует его
//    для run() — run() стартует HTTP-сервер, а UI уже подключён
//    SceneDelegate'ом.
//
// Ниже — только изменённые фрагменты. Скопируй их в свой Backend.swift
// вместо соответствующих методов.

import Foundation
import Network
import NetworkExtension
import UIKit
import UserNotifications

// ============================================================
//  В Backend.swift замени методы:
// ============================================================

/*
// --- было ---
public func run() {
    guard !running else { log("[BACKEND] already running"); return }
    running = true
    ensureDefaults()
    observeVpnStatus()
    let server = HttpServer(...)
    self.httpServer = server
    server.start()
    log("[BACKEND] LaLune iOS backend started on http://\(HOST):\(PORT)")
}

// --- стало ---
public func run() throws {
    guard !running else {
        log("[BACKEND] already running")
        return
    }

    // 1. Проверяем, что порт свободен. Если занят — бросаем исключение,
    //    SceneDelegate его поймает и покажет баннер, но приложение
    //    НЕ упадёт.
    if !isPortAvailable(port: PORT) {
        throw BackendError.portBusy(PORT)
    }

    running = true
    ensureDefaults()
    observeVpnStatus()

    // 2. Создаём HttpServer. Его start() тоже теперь бросает.
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

    do {
        try server.start()
    } catch {
        running = false
        self.httpServer = nil
        throw BackendError.httpServerStartFailed(error)
    }

    log("[BACKEND] LaLune iOS backend started on http://\(HOST):\(PORT)")
}

// --- helper ---
private func isPortAvailable(port: UInt16) -> Bool {
    // Простая проверка через bind на loopback.
    // Если порт занят — bind вернёт ошибку.
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return true } // не можем проверить — считаем свободным
    defer { close(sock) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

// --- error type ---
public enum BackendError: LocalizedError {
    case portBusy(UInt16)
    case httpServerStartFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .portBusy(let p):
            return "Порт \(p) занят — возможно, приложение уже запущено"
        case .httpServerStartFailed(let e):
            return "Не удалось запустить HTTP-сервер: \(e.localizedDescription)"
        }
    }
}
*/

// ============================================================
//  В HttpServer.swift замени start():
// ============================================================

/*
// --- было ---
func start() {
    do {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[HTTP] listening on \(self.host):\(self.port)")
            case .failed(let e):
                print("[HTTP] failed: \(e)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    } catch {
        print("[HTTP] start error: \(error)")
    }
}

// --- стало ---
func start() throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.acceptLocalOnly = true

    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        throw NSError(
            domain: "LaLune.HTTP",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"]
        )
    }

    let listener: NWListener
    do {
        listener = try NWListener(using: params, on: nwPort)
    } catch {
        throw NSError(
            domain: "LaLune.HTTP",
            code: -2,
            userInfo: [
                NSLocalizedDescriptionKey: "NWListener init failed: \(error.localizedDescription)"
            ]
        )
    }

    listener.newConnectionHandler = { [weak self] conn in
        self?.handle(conn)
    }
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            print("[HTTP] listening on \(self.host):\(self.port)")
        case .failed(let e):
            print("[HTTP] failed: \(e)")
        default: break
        }
    }
    listener.start(queue: queue)
    self.listener = listener
}
*/

