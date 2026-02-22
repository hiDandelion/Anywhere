//
//  VLESSConfiguration.swift
//  Anywhere
//
//  VLESS protocol configuration
//

import Foundation

/// VLESS protocol configuration
struct VLESSConfiguration: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let serverAddress: String
    let serverPort: UInt16
    /// Pre-resolved IP address for `serverAddress`. When set, socket connections and tunnel
    /// routing use this IP instead of the domain name to avoid DNS-over-tunnel routing loops.
    /// Populated at connect time by the app; `nil` when `serverAddress` is already an IP.
    let resolvedIP: String?
    let uuid: UUID
    let encryption: String
    /// Transport type: `"tcp"` (default), `"ws"`, `"httpupgrade"`, or `"xhttp"`.
    let transport: String
    let flow: String?
    let security: String
    let tls: TLSConfiguration?
    let reality: RealityConfiguration?
    /// WebSocket configuration when `transport == "ws"`.
    let websocket: WebSocketConfiguration?
    /// HTTP upgrade configuration when `transport == "httpupgrade"`.
    let httpUpgrade: HTTPUpgradeConfiguration?
    /// XHTTP configuration when `transport == "xhttp"`.
    let xhttp: XHTTPConfiguration?
    /// Vision padding seed: `[contentThreshold, longPaddingMax, longPaddingBase, shortPaddingMax]`.
    /// Default `[900, 500, 900, 256]` matches Xray-core.
    let testseed: [UInt32]
    /// Whether to multiplex UDP flows through the VLESS connection.
    /// Only effective when Vision flow is active. Default `true` matches Xray-core behavior.
    let muxEnabled: Bool
    /// Whether to use XUDP (GlobalID-based flow identification) for muxed UDP.
    /// Only effective when `muxEnabled` is `true`. Default `true` matches Xray-core behavior.
    let xudpEnabled: Bool

    /// The address to use for socket connections: the resolved IP if available, otherwise `serverAddress`.
    var connectAddress: String { resolvedIP ?? serverAddress }

    init(id: UUID = UUID(), name: String, serverAddress: String, serverPort: UInt16, uuid: UUID, encryption: String, transport: String = "tcp", flow: String? = nil, security: String = "none", tls: TLSConfiguration? = nil, reality: RealityConfiguration? = nil, websocket: WebSocketConfiguration? = nil, httpUpgrade: HTTPUpgradeConfiguration? = nil, xhttp: XHTTPConfiguration? = nil, testseed: [UInt32]? = nil, muxEnabled: Bool = true, xudpEnabled: Bool = true, resolvedIP: String? = nil) {
        self.id = id
        self.name = name
        self.serverAddress = serverAddress
        self.serverPort = serverPort
        self.resolvedIP = resolvedIP
        self.uuid = uuid
        self.encryption = encryption
        self.transport = transport
        self.flow = flow
        self.security = security
        self.tls = tls
        self.reality = reality
        self.websocket = websocket
        self.httpUpgrade = httpUpgrade
        self.xhttp = xhttp
        self.testseed = (testseed?.count ?? 0) >= 4 ? testseed! : [900, 500, 900, 256]
        self.muxEnabled = muxEnabled
        self.xudpEnabled = xudpEnabled
    }

    /// Convenience initializer that defaults the name to `"Untitled"`.
    init(serverAddress: String, serverPort: UInt16, uuid: UUID, encryption: String, transport: String = "tcp", flow: String?, security: String = "none", tls: TLSConfiguration? = nil, reality: RealityConfiguration? = nil, websocket: WebSocketConfiguration? = nil, httpUpgrade: HTTPUpgradeConfiguration? = nil, xhttp: XHTTPConfiguration? = nil, testseed: [UInt32]? = nil, muxEnabled: Bool = true, xudpEnabled: Bool = true, resolvedIP: String? = nil) {
        self.init(name: "Untitled", serverAddress: serverAddress, serverPort: serverPort, uuid: uuid, encryption: encryption, transport: transport, flow: flow, security: security, tls: tls, reality: reality, websocket: websocket, httpUpgrade: httpUpgrade, xhttp: xhttp, testseed: testseed, muxEnabled: muxEnabled, xudpEnabled: xudpEnabled, resolvedIP: resolvedIP)
    }

    /// Custom decoder for backward compatibility (old configs may lack newer fields like
    /// `xudpEnabled` or `resolvedIP`). Uses `decodeIfPresent` with sensible defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        serverAddress = try container.decode(String.self, forKey: .serverAddress)
        serverPort = try container.decode(UInt16.self, forKey: .serverPort)
        resolvedIP = try container.decodeIfPresent(String.self, forKey: .resolvedIP)
        uuid = try container.decode(UUID.self, forKey: .uuid)
        encryption = try container.decode(String.self, forKey: .encryption)
        transport = try container.decode(String.self, forKey: .transport)
        flow = try container.decodeIfPresent(String.self, forKey: .flow)
        security = try container.decode(String.self, forKey: .security)
        tls = try container.decodeIfPresent(TLSConfiguration.self, forKey: .tls)
        reality = try container.decodeIfPresent(RealityConfiguration.self, forKey: .reality)
        websocket = try container.decodeIfPresent(WebSocketConfiguration.self, forKey: .websocket)
        httpUpgrade = try container.decodeIfPresent(HTTPUpgradeConfiguration.self, forKey: .httpUpgrade)
        xhttp = try container.decodeIfPresent(XHTTPConfiguration.self, forKey: .xhttp)
        let ts = try container.decodeIfPresent([UInt32].self, forKey: .testseed)
        testseed = (ts?.count ?? 0) >= 4 ? ts! : [900, 500, 900, 256]
        muxEnabled = try container.decodeIfPresent(Bool.self, forKey: .muxEnabled) ?? true
        xudpEnabled = try container.decodeIfPresent(Bool.self, forKey: .xudpEnabled) ?? true
    }
    
    /// Parse a VLESS URL into configuration
    /// Format: vless://uuid@host:port/?type=tcp&encryption=none&security=none
    /// Reality format: vless://uuid@host:port/?security=reality&sni=example.com&pbk=...&sid=...&fp=chrome
    static func parse(url: String) throws -> VLESSConfiguration {
        guard url.hasPrefix("vless://") else {
            throw VLESSError.invalidURL("URL must start with vless://")
        }

        var urlWithoutScheme = String(url.dropFirst("vless://".count))

        // Extract fragment (#name) — standard VLESS share link format
        var fragmentName: String?
        if let hashIndex = urlWithoutScheme.lastIndex(of: "#") {
            fragmentName = String(urlWithoutScheme[urlWithoutScheme.index(after: hashIndex)...])
                .removingPercentEncoding
            urlWithoutScheme = String(urlWithoutScheme[..<hashIndex])
        }

        // Split by @ to get UUID and server info
        guard let atIndex = urlWithoutScheme.firstIndex(of: "@") else {
            throw VLESSError.invalidURL("Missing @ separator")
        }

        let uuidString = String(urlWithoutScheme[..<atIndex])
        let serverPart = String(urlWithoutScheme[urlWithoutScheme.index(after: atIndex)...])

        // Parse UUID
        guard let uuid = UUID(uuidString: uuidString) else {
            throw VLESSError.invalidURL("Invalid UUID: \(uuidString)")
        }

        // Split server part by /? to separate host:port from query params
        let serverAndQuery = serverPart.split(separator: "/", maxSplits: 1)
        let hostPort = String(serverAndQuery[0])

        // Parse host:port
        guard let colonIndex = hostPort.lastIndex(of: ":") else {
            throw VLESSError.invalidURL("Missing port in server address")
        }

        let host = String(hostPort[..<colonIndex])
        let portString = String(hostPort[hostPort.index(after: colonIndex)...])

        guard let port = UInt16(portString) else {
            throw VLESSError.invalidURL("Invalid port: \(portString)")
        }

        // Parse query parameters into dictionary
        var params: [String: String] = [:]

        if serverAndQuery.count > 1 {
            let queryPart = String(serverAndQuery[1])
            let queryString = queryPart.hasPrefix("?") ? String(queryPart.dropFirst()) : queryPart
            for param in queryString.split(separator: "&") {
                let keyValue = param.split(separator: "=", maxSplits: 1)
                if keyValue.count == 2 {
                    let key = String(keyValue[0])
                    let value = String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])
                    params[key] = value
                }
            }
        }

        let encryption = params["encryption"] ?? "none"
        let flow = params["flow"]
        let security = params["security"] ?? "none"
        let transport = params["type"] ?? "tcp"

        // Parse testseed (comma-separated 4 uint32 values, e.g. "900,500,900,256")
        var testseed: [UInt32]? = nil
        if let testseedStr = params["testseed"] {
            let values = testseedStr.split(separator: ",").compactMap { UInt32($0) }
            if values.count >= 4 {
                testseed = Array(values.prefix(4))
            }
        }

        // Parse Reality configuration if security=reality
        var realityConfig: RealityConfiguration? = nil
        if security == "reality" {
            do {
                realityConfig = try RealityConfiguration.parse(from: params)
            } catch {
                throw VLESSError.invalidURL("Reality configuration error: \(error.localizedDescription)")
            }
        }

        // Parse TLS configuration if security=tls
        var tlsConfig: TLSConfiguration? = nil
        if security == "tls" {
            do {
                tlsConfig = try TLSConfiguration.parse(from: params, serverAddress: host)
            } catch {
                throw VLESSError.invalidURL("TLS configuration error: \(error.localizedDescription)")
            }
        }

        // Parse WebSocket configuration if type=ws
        var wsConfig: WebSocketConfiguration? = nil
        if transport == "ws" {
            wsConfig = WebSocketConfiguration.parse(from: params, serverAddress: host)
        }

        // Parse HTTP upgrade configuration if type=httpupgrade
        var httpUpgradeConfig: HTTPUpgradeConfiguration? = nil
        if transport == "httpupgrade" {
            httpUpgradeConfig = HTTPUpgradeConfiguration.parse(from: params, serverAddress: host)
        }

        // Parse XHTTP configuration if type=xhttp
        var xhttpConfig: XHTTPConfiguration? = nil
        if transport == "xhttp" {
            xhttpConfig = XHTTPConfiguration.parse(from: params, serverAddress: host)
        }

        // Parse mux and xudp flags (default true, matching Xray-core behavior)
        let muxEnabled = params["mux"].map { $0 != "false" && $0 != "0" } ?? true
        let xudpEnabled = params["xudp"].map { $0 != "false" && $0 != "0" } ?? true

        return VLESSConfiguration(
            name: fragmentName ?? "Untitled",
            serverAddress: host,
            serverPort: port,
            uuid: uuid,
            encryption: encryption,
            transport: transport,
            flow: flow,
            security: security,
            tls: tlsConfig,
            reality: realityConfig,
            websocket: wsConfig,
            httpUpgrade: httpUpgradeConfig,
            xhttp: xhttpConfig,
            testseed: testseed,
            muxEnabled: muxEnabled,
            xudpEnabled: xudpEnabled
        )
    }

}

enum VLESSError: Error, LocalizedError {
    case invalidURL(String)
    case connectionFailed(String)
    case protocolError(String)
    case invalidResponse(String)
    case dropped

    var errorDescription: String? {
        switch self {
        case .invalidURL(let message):
            return "Invalid VLESS URL: \(message)"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .protocolError(let message):
            return "Protocol error: \(message)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .dropped:
            return nil
        }
    }
}
