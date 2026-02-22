//
//  PacketTunnelProvider.swift
//  Network Extension
//
//  Created by Junhui Lou on 1/23/26.
//

import NetworkExtension
import Network
import os.log

private let logger = Logger(subsystem: "com.argsment.Anywhere.Network-Extension", category: "PacketTunnel")

class PacketTunnelProvider: NEPacketTunnelProvider {
    private let lwipStack = LWIPStack()

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let configDict = options?["config"] as? [String: Any],
              let config = Self.parseConfiguration(from: configDict) else {
            logger.error("[VPN] Invalid or missing configuration in options")
            completionHandler(NSError(domain: "com.argsment.Anywhere", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid configuration"]))
            return
        }

        let remoteAddress = config.connectAddress
        logger.info("[VPN] Starting tunnel to \(config.serverAddress, privacy: .public):\(config.serverPort, privacy: .public) (connect: \(remoteAddress, privacy: .public)), security: \(config.security, privacy: .public), transport: \(config.transport, privacy: .public)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        let ipv4Settings = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: remoteAddress, subnetMask: "255.255.255.255")
        ]
        settings.ipv4Settings = ipv4Settings

        let ipv6Enabled = UserDefaults(suiteName: "group.com.argsment.Anywhere")?.bool(forKey: "ipv6Enabled") ?? false
        if ipv6Enabled {
            let ipv6Settings = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
            ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6Settings
        }

        let dnsServers: [String]
        if ipv6Enabled {
            dnsServers = ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
        } else {
            dnsServers = ["1.1.1.1", "1.0.0.1"]
        }
        let dnsSettings = NEDNSSettings(servers: dnsServers)
        settings.dnsSettings = dnsSettings
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { error in
            if let error {
                logger.error("[VPN] Failed to set tunnel settings: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }

            self.lwipStack.start(packetFlow: self.packetFlow,
                                 configuration: config,
                                 ipv6Enabled: ipv6Enabled)
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lwipStack.stop()
        completionHandler()
    }

    // MARK: - App Messages

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Parse incoming config switch request
        guard let configDict = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let config = Self.parseConfiguration(from: configDict) else {
            completionHandler?(nil)
            return
        }

        logger.info("[VPN] Received config switch request, switching configuration")
        lwipStack.switchConfiguration(config)
        completionHandler?(nil)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
    }

    // MARK: - Configuration Parsing

    /// Parses a VLESS configuration from a dictionary.
    ///
    /// Shared between `startTunnel` (from options) and `handleAppMessage` (from JSON).
    static func parseConfiguration(from configDict: [String: Any]) -> VLESSConfiguration? {
        guard let serverAddress = configDict["serverAddress"] as? String,
              let uuidString = configDict["uuid"] as? String,
              let uuid = UUID(uuidString: uuidString),
              let encryption = configDict["encryption"] as? String else {
            return nil
        }

        // serverPort may arrive as UInt16 (from startTunnel options) or Int (from JSON)
        let serverPort: UInt16
        if let port = configDict["serverPort"] as? UInt16 {
            serverPort = port
        } else if let port = configDict["serverPort"] as? Int, port > 0, port <= UInt16.max {
            serverPort = UInt16(port)
        } else {
            return nil
        }

        let flow = (configDict["flow"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let security = (configDict["security"] as? String) ?? "none"

        // Parse Reality configuration if present
        var realityConfig: RealityConfiguration? = nil
        if security == "reality",
           let serverName = configDict["realityServerName"] as? String,
           let publicKeyBase64 = configDict["realityPublicKey"] as? String,
           let publicKey = Data(base64Encoded: publicKeyBase64),
           publicKey.count == 32 {
            let shortIdHex = (configDict["realityShortId"] as? String) ?? ""
            let shortId = Data(hexString: shortIdHex) ?? Data()
            let fpString = (configDict["realityFingerprint"] as? String) ?? "chrome_120"
            let fingerprint = TLSFingerprint(rawValue: fpString) ?? .chrome120

            realityConfig = RealityConfiguration(
                serverName: serverName,
                publicKey: publicKey,
                shortId: shortId,
                fingerprint: fingerprint
            )
        }

        // Parse TLS configuration if present
        var tlsConfig: TLSConfiguration? = nil
        if security == "tls" {
            let sni = (configDict["tlsServerName"] as? String) ?? serverAddress
            var alpn: [String]? = nil
            if let alpnString = configDict["tlsAlpn"] as? String, !alpnString.isEmpty {
                alpn = alpnString.split(separator: ",").map { String($0) }
            }
            let allowInsecure = (configDict["tlsAllowInsecure"] as? Bool) ?? false

            tlsConfig = TLSConfiguration(
                serverName: sni,
                alpn: alpn,
                allowInsecure: allowInsecure
            )
        }

        // Parse transport and WebSocket configuration
        let transport = (configDict["transport"] as? String) ?? "tcp"

        var wsConfig: WebSocketConfiguration? = nil
        if transport == "ws" {
            let wsHost = (configDict["wsHost"] as? String) ?? serverAddress
            let wsPath = (configDict["wsPath"] as? String) ?? "/"
            var wsHeaders: [String: String] = [:]
            if let headersString = configDict["wsHeaders"] as? String, !headersString.isEmpty {
                for pair in headersString.split(separator: ",") {
                    let kv = pair.split(separator: ":", maxSplits: 1)
                    if kv.count == 2 {
                        wsHeaders[String(kv[0])] = String(kv[1])
                    }
                }
            }
            let wsMaxEarlyData = (configDict["wsMaxEarlyData"] as? Int) ?? 0
            let wsEarlyDataHeaderName = (configDict["wsEarlyDataHeaderName"] as? String) ?? "Sec-WebSocket-Protocol"

            wsConfig = WebSocketConfiguration(
                host: wsHost,
                path: wsPath,
                headers: wsHeaders,
                maxEarlyData: wsMaxEarlyData,
                earlyDataHeaderName: wsEarlyDataHeaderName
            )
        }

        // Parse HTTP upgrade configuration if transport=httpupgrade
        var huConfig: HTTPUpgradeConfiguration? = nil
        if transport == "httpupgrade" {
            let huHost = (configDict["huHost"] as? String) ?? serverAddress
            let huPath = (configDict["huPath"] as? String) ?? "/"
            var huHeaders: [String: String] = [:]
            if let headersString = configDict["huHeaders"] as? String, !headersString.isEmpty {
                for pair in headersString.split(separator: ",") {
                    let kv = pair.split(separator: ":", maxSplits: 1)
                    if kv.count == 2 {
                        huHeaders[String(kv[0])] = String(kv[1])
                    }
                }
            }

            huConfig = HTTPUpgradeConfiguration(
                host: huHost,
                path: huPath,
                headers: huHeaders
            )
        }

        // Parse XHTTP configuration if transport=xhttp
        var xhttpConfig: XHTTPConfiguration? = nil
        if transport == "xhttp" {
            let xhttpHost = (configDict["xhttpHost"] as? String) ?? serverAddress
            let xhttpPath = (configDict["xhttpPath"] as? String) ?? "/"
            let xhttpModeStr = (configDict["xhttpMode"] as? String) ?? "auto"
            let xhttpMode = XHTTPMode(rawValue: xhttpModeStr) ?? .auto
            var xhttpHeaders: [String: String] = [:]
            if let headersString = configDict["xhttpHeaders"] as? String, !headersString.isEmpty {
                for pair in headersString.split(separator: ",") {
                    let kv = pair.split(separator: ":", maxSplits: 1)
                    if kv.count == 2 {
                        xhttpHeaders[String(kv[0])] = String(kv[1])
                    }
                }
            }
            let xhttpNoGRPCHeader = (configDict["xhttpNoGRPCHeader"] as? Bool) ?? false

            xhttpConfig = XHTTPConfiguration(
                host: xhttpHost,
                path: xhttpPath,
                mode: xhttpMode,
                headers: xhttpHeaders,
                noGRPCHeader: xhttpNoGRPCHeader
            )
        }

        let muxEnabled = (configDict["muxEnabled"] as? Bool) ?? true
        let xudpEnabled = (configDict["xudpEnabled"] as? Bool) ?? true
        let resolvedIP = configDict["resolvedIP"] as? String

        return VLESSConfiguration(
            serverAddress: serverAddress,
            serverPort: serverPort,
            uuid: uuid,
            encryption: encryption,
            transport: transport,
            flow: flow,
            security: security,
            tls: tlsConfig,
            reality: realityConfig,
            websocket: wsConfig,
            httpUpgrade: huConfig,
            xhttp: xhttpConfig,
            muxEnabled: muxEnabled,
            xudpEnabled: xudpEnabled,
            resolvedIP: resolvedIP
        )
    }
}
