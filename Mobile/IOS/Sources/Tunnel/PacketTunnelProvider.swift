import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var udpConnection: NWConnection?
    private var isRunning = true
    private let corePort: UInt16 = 52230
    private let appGroup = "group.com.lalune"
    private var isCoreStarted = false
    
    // Файл для логов
    private var logFileURL: URL {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return (container ?? FileManager.default.temporaryDirectory).appendingPathComponent("tunnel.log")
    }
    
    // C-ABI колбэк для логов из ядра
    private let logCallback: csqtt_log_callback = { message in
        guard let message = message else { return }
        let logString = String(cString: message)
        NSLog("[CSQTT] %@", logString)
        
        // Пишем в общий файл логов
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.lalune") {
            let logURL = container.appendingPathComponent("tunnel.log")
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write((logString + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? (logString + "\n").write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
    }
    
    // Логирование в файл
    private func log(_ message: String) {
        NSLog("[TUNNEL] %@", message)
        
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        let logURL = (container ?? FileManager.default.temporaryDirectory).appendingPathComponent("tunnel.log")
        
        let line = "[\(Date())] \(message)\n"
        
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log("=== startTunnel called ===")
        
        let sharedDefaults = UserDefaults(suiteName: appGroup)
        let peer = sharedDefaults?.string(forKey: "peer") ?? ""
        let password = sharedDefaults?.string(forKey: "password") ?? ""
        let hashes = sharedDefaults?.string(forKey: "hashes") ?? ""
        let workers = sharedDefaults?.integer(forKey: "workers") ?? 9
        let deviceId = sharedDefaults?.string(forKey: "deviceId") ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let obfs = sharedDefaults?.string(forKey: "obfs") ?? "video"
        let fingerprint = sharedDefaults?.string(forKey: "fingerprint") ?? "firefox"
        let clientIds = sharedDefaults?.string(forKey: "clientIds") ?? "8202606,6287487"
        let vkAuthMode = sharedDefaults?.string(forKey: "vkAuthMode") ?? "vkcalls"
        let captchaMode = sharedDefaults?.string(forKey: "captchaMode") ?? "auto"
        
        log("Config: peer=\(peer), workers=\(workers), obfs=\(obfs), fingerprint=\(fingerprint)")
        log("Hashes count: \(hashes.components(separatedBy: ",").count)")
        
        // Устанавливаем колбэк для логов ядра
        log("Setting up C callback...")
        csqtt_set_log_callback(logCallback)
        log("C callback set")
        
        // Настройка TUN
        log("Configuring TUN...")
        let tunIP = "10.66.67.12"
        let dnsServers = ["8.8.8.8", "8.8.4.4"]
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunIP)
        let ipv4 = NEIPv4Settings(addresses: [tunIP], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        settings.mtu = 1300
        
        log("TUN settings created: IP=\(tunIP), DNS=\(dnsServers), MTU=1300")
        
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                self.log("ERROR: setTunnelNetworkSettings failed: \(error)")
                completionHandler(error)
                return
            }
            
            self.log("TUN settings applied successfully")
            
            // Запускаем ядро
            self.log("Starting core...")
            DispatchQueue.global().async {
                self.startCore(
                    peer: peer,
                    password: password,
                    hashes: hashes,
                    workers: workers,
                    deviceId: deviceId,
                    obfs: obfs,
                    fingerprint: fingerprint,
                    clientIds: clientIds,
                    vkAuthMode: vkAuthMode,
                    captchaMode: captchaMode
                )
            }
            
            // Ждём и запускаем UDP мост
            self.log("Waiting 2s for core to start...")
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                self.startUDPBridge(completionHandler: completionHandler)
            }
        }
    }
    
    private func startCore(
        peer: String,
        password: String,
        hashes: String,
        workers: Int,
        deviceId: String,
        obfs: String,
        fingerprint: String,
        clientIds: String,
        vkAuthMode: String,
        captchaMode: String
    ) {
        let listenAddr = "127.0.0.1:\(corePort)"
        
        log("Calling csqtt_run:")
        log("  peer: \(peer)")
        log("  hashes: \(hashes)")
        log("  workers: \(workers)")
        log("  listen: \(listenAddr)")
        log("  obfs: \(obfs)")
        log("  fingerprint: \(fingerprint)")
        log("  clientIds: \(clientIds)")
        log("  vkAuthMode: \(vkAuthMode)")
        log("  captchaMode: \(captchaMode)")
        
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
            log("csqtt_run returned SUCCESS (0)")
        } else {
            log("ERROR: csqtt_run returned \(result)")
        }
    }
    
    private func startUDPBridge(completionHandler: @escaping (Error?) -> Void) {
        log("Starting UDP bridge to 127.0.0.1:\(corePort)...")
        
        let host = NWEndpoint.Host("127.0.0.1")
        let port = NWEndpoint.Port(rawValue: corePort)!
        
        udpConnection = NWConnection(host: host, port: port, using: .udp)
        udpConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.log("UDP bridge connected")
                completionHandler(nil)
                self.startReadingFromTun()
                self.startReadingFromUDP()
            case .failed(let error):
                self.log("ERROR: UDP bridge failed: \(error)")
                completionHandler(error)
            case .cancelled:
                self.log("UDP bridge cancelled")
            default:
                break
            }
        }
        udpConnection?.start(queue: .global())
    }
    
    private func startReadingFromTun() {
        guard isRunning else { return }
        
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            for packet in packets {
                self.udpConnection?.send(content: packet, completion: .contentProcessed { _ in })
            }
            self.startReadingFromTun()
        }
    }
    
    private func startReadingFromUDP() {
        guard isRunning else { return }
        
        udpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, error == nil {
                let packets = [Data](arrayLiteral: data)
                let protocols = [NSNumber](arrayLiteral: NSNumber(value: AF_INET))
                self.packetFlow.writePackets(packets, withProtocols: protocols)
            }
            self.startReadingFromUDP()
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("=== stopTunnel called ===")
        isRunning = false
        udpConnection?.cancel()
        if isCoreStarted {
            log("Calling csqtt_stop...")
            csqtt_stop()
            log("csqtt_stop called")
        }
        log("Tunnel stopped")
        completionHandler()
    }
}
