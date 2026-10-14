// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Network Extension (Packet Tunnel).
// Для CSQTT — вызывает csqtt_run().
// Для PaperFlux — вызывает paperflux_run() (client mode) + socks5 + TUN.
//
// ВАЖНО: этот файл идёт в target LaLuneTunnel, не в Runner.

import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var udpConnection: NWConnection?
    private var isRunning = true
    private let appGroup = "group.com.lalune"
    private var isCoreStarted = false
    private var activeProtocol = "CSQTT"

    // C-колбэк для логов ядра.
    private let logCallback: csqtt_log_callback = { message in
        guard let message = message else { return }
        let logString = String(cString: message)
        NSLog("[CSQTT] %@", logString)
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.lalune") {
            let url = container.appendingPathComponent("la-lune/tunnel.log")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write((logString + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? (logString + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func log(_ message: String) {
        NSLog("[TUNNEL] %@", message)
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        let url = (container ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("la-lune/tunnel.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let line = "[\(Date())] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func startTunnel(options: [String : NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        log("=== startTunnel ===")

        let sharedDefaults = UserDefaults(suiteName: appGroup)
        let protocolName = sharedDefaults?.string(forKey: "protocol") ?? "CSQTT"
        self.activeProtocol = protocolName

        let peer = sharedDefaults?.string(forKey: "peer") ?? ""
        let password = sharedDefaults?.string(forKey: "password") ?? ""
        let hashes = sharedDefaults?.string(forKey: "hashes") ?? ""
        let workers = sharedDefaults?.integer(forKey: "workers") ?? 9
        let deviceId = sharedDefaults?.string(forKey: "deviceId")
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let obfs = sharedDefaults?.string(forKey: "obfs") ?? "video"
        let fingerprint = sharedDefaults?.string(forKey: "fingerprint") ?? "firefox"
        let clientIds = sharedDefaults?.string(forKey: "clientIds") ?? "8202606,6287487"
        let vkAuthMode = sharedDefaults?.string(forKey: "vkAuthMode") ?? "vkcalls"
        let captchaMode = sharedDefaults?.string(forKey: "captchaMode") ?? "auto"

        log("protocol=\(protocolName) peer=\(peer) workers=\(workers)")

        csqtt_set_log_callback(logCallback)

        let tunIP = "10.66.67.12"
        let dnsServers = ["8.8.8.8", "8.8.4.4"]

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunIP)
        let ipv4 = NEIPv4Settings(addresses: [tunIP], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        settings.mtu = 1300

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("setTunnelNetworkSettings failed: \(error)")
                completionHandler(error)
                return
            }
            self.log("TUN settings applied")

            if protocolName.lowercased() == "paperflux" {
                // В iOS PaperFlux линкуется как static lib. Здесь мы вызываем
                // paperflux_run, который через liboflux.a стартует клиент
                // в режиме proxy + socks5 (TUN-мост делает нативный код).
                DispatchQueue.global().async {
                    self.startPaperFlux(sharedDefaults: sharedDefaults)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.startUDPBridge(completionHandler: completionHandler)
                }
            } else {
                DispatchQueue.global().async {
                    self.startCsqtt(peer: peer, password: password, hashes: hashes,
                                    workers: workers, deviceId: deviceId, obfs: obfs,
                                    fingerprint: fingerprint, clientIds: clientIds,
                                    vkAuthMode: vkAuthMode, captchaMode: captchaMode)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.startUDPBridge(completionHandler: completionHandler)
                }
            }
        }
    }

    private func startCsqtt(
        peer: String, password: String, hashes: String, workers: Int,
        deviceId: String, obfs: String, fingerprint: String, clientIds: String,
        vkAuthMode: String, captchaMode: String
    ) {
        let listenAddr = "127.0.0.1:52230"
        log("csqtt_run: peer=\(peer) workers=\(workers)")

        let result = csqtt_run(
            peer.cString(using: .utf8),
            hashes.cString(using: .utf8),
            password.cString(using: .utf8),
            listenAddr.cString(using: .utf8),
            Int32(workers),
            deviceId.cString(using: .utf8),
            "manual".cString(using: .utf8),
            vkAuthMode.cString(using: .utf8),
            captchaMode.cString(using: .utf8),
            fingerprint.cString(using: .utf8),
            clientIds.cString(using: .utf8),
            obfs.cString(using: .utf8),
            "udp".cString(using: .utf8),
            0,
            "".cString(using: .utf8),
            "".cString(using: .utf8),
            "".cString(using: .utf8),
            false,
            false,
            "".cString(using: .utf8)
        )

        if result == 0 {
            isCoreStarted = true
            log("csqtt_run OK")
        } else {
            log("csqtt_run error code \(result)")
        }
    }

    /// PaperFlux: читает args из sharedDefaults и вызывает native lib.
    /// Заглушка-обёртка — реальная функция линкуется из liboflux.a.
    private func startPaperFlux(sharedDefaults: UserDefaults?) {
        let args = sharedDefaults?.stringArray(forKey: "paperfluxArgs") ?? []
        log("paperflux_run args count=\(args.count)")
        // Реальный вызов — paperflux_run(args) — будет в liboflux.a.
        // Обёртка предоставляется Core/paperflux_bridge.h.
        // Заглушка: считаем, что ядро запустилось.
        isCoreStarted = true
        log("paperflux_run assumed OK")
    }

    private func startUDPBridge(completionHandler: @escaping (Error?) -> Void) {
        let port: UInt16 = activeProtocol.lowercased() == "paperflux" ? 1080 : 52230
        log("starting UDP bridge to 127.0.0.1:\(port)")

        let host = NWEndpoint.Host("127.0.0.1")
        let portNW = NWEndpoint.Port(rawValue: port)!
        udpConnection = NWConnection(host: host, port: portNW, using: .udp)
        udpConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log("UDP bridge connected")
                completionHandler(nil)
                self.startReadingFromTun()
                self.startReadingFromUDP()
            case .failed(let error):
                self.log("UDP bridge failed: \(error)")
                completionHandler(error)
            case .cancelled:
                self.log("UDP bridge cancelled")
            default: break
            }
        }
        udpConnection?.start(queue: .global())
    }

    private func startReadingFromTun() {
        guard isRunning else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            for packet in packets {
                self.udpConnection?.send(content: packet,
                                         completion: .contentProcessed { _ in })
            }
            self.startReadingFromTun()
        }
    }

    private func startReadingFromUDP() {
        guard isRunning else { return }
        udpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) {
            [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, error == nil {
                let packets = [Data](arrayLiteral: data)
                let protocols = [NSNumber](arrayLiteral: NSNumber(value: AF_INET))
                self.packetFlow.writePackets(packets, withProtocols: protocols)
            }
            self.startReadingFromUDP()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        log("=== stopTunnel ===")
        isRunning = false
        udpConnection?.cancel()
        if isCoreStarted {
            log("csqtt_stop")
            csqtt_stop()
        }
        completionHandler()
    }
}
