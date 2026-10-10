// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// SOCKS5-сервер для раздачи VPN на iOS.
//
// ВАЖНО: этот файл лежит в Frontend/ios/Runner/ — именно здесь Xcode
// ищет исходники основного target'а. Файл в Backend/iOS/Socks5Server.swift
// используется как "референсный" и в сборку не входит.
//
// Слушает 0.0.0.0:1080. Все CONNECT-запросы идут через TUN
// (default route уже указывает на VPN-туннель).
//
// Логирует "[PROXY] Listening socks5 on <real-ip>:1080".

import Foundation
import Network

@available(iOS 17.0, *)
final class Socks5Server {

    private let port: UInt16
    private let log: (String) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lalune.socks5", attributes: .concurrent)

    init(port: UInt16, log: @escaping (String) -> Void) {
        self.port = port
        self.log = log
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "Socks5", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port"])
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let ip = self.localIpAddress() ?? "0.0.0.0"
                self.log("[PROXY] Listening socks5 on \(ip):\(self.port)")
            case .failed(let e):
                self.log("[PROXY] listener failed: \(e.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        log("[PROXY] stopped")
    }

    // ============================================================
    //  Обработка клиента
    // ============================================================

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readGreeting(conn)
    }

    private func readGreeting(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count == 2 else {
                conn.cancel(); return
            }
            if data[0] != 0x05 {
                conn.cancel(); return
            }
            let nMethods = Int(data[1])
            if nMethods <= 0 {
                conn.cancel(); return
            }
            conn.receive(minimumIncompleteLength: nMethods, maximumLength: nMethods) { data2, _, _, _ in
                guard let data2 = data2, data2.count == nMethods else {
                    conn.cancel(); return
                }
                // Отвечаем "no auth"
                conn.send(content: Data([0x05, 0x00]), completion: .contentProcessed { _ in
                    self.readRequest(conn)
                })
            }
        }
    }

    private func readRequest(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count == 4 else {
                conn.cancel(); return
            }
            if data[0] != 0x05 || data[1] != 0x01 {
                // Только CONNECT
                conn.send(content: Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            let atyp = data[3]
            switch atyp {
            case 0x01:
                self.readIPv4(conn)
            case 0x03:
                self.readDomain(conn)
            case 0x04:
                self.readIPv6(conn)
            default:
                conn.cancel()
            }
        }
    }

    private func readIPv4(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 6, maximumLength: 6) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count == 6 else {
                conn.cancel(); return
            }
            let host = "\(data[0]).\(data[1]).\(data[2]).\(data[3])"
            let port = (UInt16(data[4]) << 8) | UInt16(data[5])
            self.connectRemote(conn, host: host, port: port)
        }
    }

    private func readDomain(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count == 1 else {
                conn.cancel(); return
            }
            let len = Int(data[0])
            if len <= 0 { conn.cancel(); return }
            conn.receive(minimumIncompleteLength: len + 2, maximumLength: len + 2) { data2, _, _, _ in
                guard let data2 = data2, data2.count == len + 2 else {
                    conn.cancel(); return
                }
                let hostData = data2.prefix(len)
                let host = String(data: hostData, encoding: .utf8) ?? ""
                let port = (UInt16(data2[len]) << 8) | UInt16(data2[len + 1])
                self.connectRemote(conn, host: host, port: port)
            }
        }
    }

    private func readIPv6(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 18, maximumLength: 18) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, data.count == 18 else {
                conn.cancel(); return
            }
            var groups: [String] = []
            for i in 0..<8 {
                let hi = UInt16(data[i * 2])
                let lo = UInt16(data[i * 2 + 1])
                groups.append(String(format: "%x", (hi << 8) | lo))
            }
            let host = groups.joined(separator: ":")
            let port = (UInt16(data[16]) << 8) | UInt16(data[17])
            self.connectRemote(conn, host: host, port: port)
        }
    }

    private func connectRemote(_ client: NWConnection, host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            client.cancel(); return
        }
        let remote = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        remote.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                // Успешный ответ
                client.send(content: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                            completion: .contentProcessed { _ in
                    self.pump(client, remote)
                })
            case .failed, .cancelled:
                client.send(content: Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                            completion: .contentProcessed { _ in client.cancel() })
            default:
                break
            }
        }
        remote.start(queue: queue)
    }

    private func pump(_ a: NWConnection, _ b: NWConnection) {
        func forward(_ from: NWConnection, _ to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    to.send(content: data, completion: .contentProcessed { _ in
                        forward(from, to)
                    })
                } else if error != nil || isComplete {
                    from.cancel(); to.cancel()
                } else {
                    forward(from, to)
                }
            }
        }
        forward(a, b)
        forward(b, a)
    }

    // ============================================================
    //  Локальный IP
    // ============================================================

    private func localIpAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = first
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name != "lo0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr,
                                socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        return address
    }
}
