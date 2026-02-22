//
//  TLSConfiguration.swift
//  Anywhere
//
//  Standard TLS transport configuration
//

import Foundation

/// Standard TLS transport configuration for VLESS connections.
struct TLSConfiguration {
    let serverName: String      // SNI (defaults to server address)
    let alpn: [String]?         // ALPN protocols (e.g. ["h2", "http/1.1"])
    let allowInsecure: Bool     // Skip certificate verification

    init(serverName: String, alpn: [String]? = nil, allowInsecure: Bool = false) {
        self.serverName = serverName
        self.alpn = alpn
        self.allowInsecure = allowInsecure
    }

    /// Parse TLS parameters from VLESS URL query parameters.
    ///
    /// Expected parameters: `security=tls&sni=example.com&alpn=h2,http/1.1&allowInsecure=1`
    static func parse(from params: [String: String], serverAddress: String) throws -> TLSConfiguration? {
        guard params["security"] == "tls" else { return nil }

        let sni = params["sni"] ?? serverAddress

        var alpn: [String]? = nil
        if let alpnString = params["alpn"], !alpnString.isEmpty {
            alpn = alpnString.split(separator: ",").map { String($0) }
        }

        let allowInsecure = params["allowInsecure"] == "1" || params["allowInsecure"] == "true"

        return TLSConfiguration(
            serverName: sni,
            alpn: alpn,
            allowInsecure: allowInsecure
        )
    }
}

extension TLSConfiguration: Codable {
    enum CodingKeys: String, CodingKey {
        case serverName, alpn, allowInsecure
    }
}

extension TLSConfiguration: Equatable, Hashable {
    static func == (lhs: TLSConfiguration, rhs: TLSConfiguration) -> Bool {
        lhs.serverName == rhs.serverName &&
        lhs.alpn == rhs.alpn &&
        lhs.allowInsecure == rhs.allowInsecure
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(serverName)
        hasher.combine(alpn)
        hasher.combine(allowInsecure)
    }
}

/// TLS transport errors
enum TLSError: Error, LocalizedError {
    case handshakeFailed(String)
    case certificateValidationFailed(String)
    case connectionFailed(String)
    case unsupportedTLSVersion

    var errorDescription: String? {
        switch self {
        case .handshakeFailed(let reason):
            return "TLS handshake failed: \(reason)"
        case .certificateValidationFailed(let reason):
            return "TLS certificate validation failed: \(reason)"
        case .connectionFailed(let reason):
            return "TLS connection failed: \(reason)"
        case .unsupportedTLSVersion:
            return "Server does not support TLS 1.3"
        }
    }
}
