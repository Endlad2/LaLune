import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var udpConnection: NWConnection?
    private var isRunning = true
    private let corePort: UInt16 = 52230
    private let appGroup = "group.com.lalune"
    private var isCoreStarted = false
    
    // C-ABI колбэк для логов
    private let logCallback: csqtt_log_callback = { message in
        guard let message = message else { return }
        let logString = String(cString: message)
        NSLog("[CSQTT] %@", logString)
    }
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
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
        
        // Устанавливаем колбэк для логов
        csqtt_set_log_callback(logCallback)
        
        // Запускаем ядро в отдельном потоке
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
        
        let tunIP = "10.66.67.12"
        let dnsServers = ["8.8.8.8", "8.8.4.4"]
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunIP)
        let ipv4 = NEIPv4Settings(addresses: [tunIP], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        settings.mtu = 1300
        
        setTunnelNetworkSettings(settings) { error in
            guard error == nil else {
                completionHandler(error)
                return
            }
            
            // Ждём пока ядро запустится и начнёт слушать
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
            NSLog("[CSQTT] Core started successfully")
        } else {
            NSLog("[CSQTT] Core failed with code: \(result)")
        }
    }
    
    private func startUDPBridge(completionHandler: @escaping (Error?) -> Void) {
        let host = NWEndpoint.Host("127.0.0.1")
        let port = NWEndpoint.Port(rawValue: corePort)!
        
        udpConnection = NWConnection(host: host, port: port, using: .udp)
        udpConnection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                completionHandler(nil)
                self?.startReadingFromTun()
                self?.startReadingFromUDP()
            case .failed(let error):
                completionHandler(error)
            default:
                break
            }
        }
        udpConnection?.start(queue: .global())
    }
    
    private func startReadingFromTun() {
        guard isRunning else { return }
        
        packetFlow.readPackets { [weak self] packets, _ in
            for packet in packets {
                self?.udpConnection?.send(content: packet, completion: .contentProcessed { _ in })
            }
            self?.startReadingFromTun()
        }
    }
    
    private func startReadingFromUDP() {
        guard isRunning else { return }
        
        udpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, _, error in
            if let data = data, error == nil {
                let packets = [Data](arrayLiteral: data)
                let protocols = [NSNumber](arrayLiteral: NSNumber(value: AF_INET))
                self?.packetFlow.writePackets(packets, withProtocols: protocols)
            }
            self?.startReadingFromUDP()
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        isRunning = false
        udpConnection?.cancel()
        if isCoreStarted {
            csqtt_stop()
        }
        completionHandler()
    }
}
