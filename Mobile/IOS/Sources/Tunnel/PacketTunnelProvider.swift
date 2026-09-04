import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var udpConnection: NWConnection?
    private var isRunning = true
    private let corePort: UInt16 = 52230
    private let appGroup = "group.com.lalune"
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let sharedDefaults = UserDefaults(suiteName: appGroup)
        let peer = sharedDefaults?.string(forKey: "peer") ?? ""
        let password = sharedDefaults?.string(forKey: "password") ?? ""
        let hashes = sharedDefaults?.string(forKey: "hashes") ?? ""
        let workers = sharedDefaults?.integer(forKey: "workers") ?? 9
        
        // Запускаем ядро
        startCore(peer: peer, password: password, hashes: hashes, workers: workers)
        
        // Получаем TUN IP (от ядра или дефолт)
        let tunIP = "10.66.67.12"
        let dnsServers = ["8.8.8.8", "8.8.4.4"]
        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunIP)
        let ipv4 = NEIPv4Settings(addresses: [tunIP], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.defaultRoute()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        settings.mtu = 1300
        
        setTunnelNetworkSettings(settings) { error in
            guard error == nil else {
                completionHandler(error)
                return
            }
            
            self.startUDPBridge(completionHandler: completionHandler)
        }
    }
    
    private func startCore(peer: String, password: String, hashes: String, workers: Int) {
        // Вызов C-интерфейса Rust-ядра
        // csqtt_core_start(peer, password, hashes, workers, corePort)
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
        // csqtt_core_stop()
        completionHandler()
    }
}
