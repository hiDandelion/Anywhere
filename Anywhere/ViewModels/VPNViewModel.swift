//
//  VPNViewModel.swift
//  Anywhere
//
//  ViewModel for VPN connection management
//

import Foundation
import NetworkExtension
import Combine
import SwiftUI

/// ViewModel managing VPN connection state and operations
@MainActor
class VPNViewModel: ObservableObject {
    @Published var vpnStatus: NEVPNStatus = .disconnected
    @Published var selectedConfiguration: VLESSConfiguration?
    @Published private(set) var configurations: [VLESSConfiguration] = []

    private let store = ConfigurationStore.shared
    private var vpnManager: NETunnelProviderManager?
    private var statusObserver: AnyCancellable?
    private var storeCancellable: AnyCancellable?
    private var selectionCancellable: AnyCancellable?

    private static let selectedConfigKey = "selectedConfigurationId"

    init() {
        configurations = store.configurations

        // Restore selected configuration from UserDefaults
        if let savedId = UserDefaults.standard.string(forKey: Self.selectedConfigKey),
           let uuid = UUID(uuidString: savedId),
           let config = configurations.first(where: { $0.id == uuid }) {
            selectedConfiguration = config
        } else {
            selectedConfiguration = configurations.first
        }

        storeCancellable = store.$configurations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newConfigs in
                guard let self else { return }
                self.configurations = newConfigs
                // Keep selection valid
                if let selected = self.selectedConfiguration,
                   !newConfigs.contains(where: { $0.id == selected.id }) {
                    self.selectedConfiguration = newConfigs.first
                }
                if self.selectedConfiguration == nil {
                    self.selectedConfiguration = newConfigs.first
                }
            }

        // Observe selection changes: persist to UserDefaults and send to tunnel if connected
        selectionCancellable = $selectedConfiguration
            .dropFirst() // Skip initial value emitted on subscribe
            .sink { [weak self] config in
                guard let self else { return }
                if let config {
                    UserDefaults.standard.set(config.id.uuidString, forKey: Self.selectedConfigKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.selectedConfigKey)
                }
                // If VPN is connected, push new config to the tunnel
                if self.vpnStatus == .connected, let config {
                    self.sendConfigurationToTunnel(config)
                }
            }

        setupStatusObserver()
        setupVPNManager()
    }

    // MARK: - Computed Properties

    var hasConfigurations: Bool {
        !configurations.isEmpty
    }

    var statusColor: Color {
        switch vpnStatus {
        case .connected:
            return .green
        case .connecting, .reasserting:
            return .yellow
        case .disconnecting:
            return .orange
        case .disconnected, .invalid:
            return .red
        @unknown default:
            return .gray
        }
    }

    var statusText: String {
        switch vpnStatus {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnecting:
            return "Disconnecting..."
        case .reasserting:
            return "Reconnecting..."
        case .disconnected:
            return "Disconnected"
        case .invalid:
            return "Not Configured"
        @unknown default:
            return "Unknown"
        }
    }

    var buttonText: String {
        switch vpnStatus {
        case .connected:
            return "Disconnect"
        case .connecting:
            return "Connecting..."
        case .disconnecting:
            return "Disconnecting..."
        default:
            return "Connect"
        }
    }

    var isButtonDisabled: Bool {
        !hasConfigurations || vpnStatus == .connecting || vpnStatus == .disconnecting
    }

    // MARK: - Configuration CRUD

    func addConfiguration(_ configuration: VLESSConfiguration) {
        store.add(configuration)
        if selectedConfiguration == nil {
            selectedConfiguration = configuration
        }
    }

    func updateConfiguration(_ configuration: VLESSConfiguration) {
        store.update(configuration)
        if selectedConfiguration?.id == configuration.id {
            selectedConfiguration = configuration
        }
    }

    func deleteConfiguration(_ configuration: VLESSConfiguration) {
        store.delete(configuration)
    }

    // MARK: - Setup

    private func setupStatusObserver() {
        statusObserver = NotificationCenter.default
            .publisher(for: .NEVPNStatusDidChange)
            .compactMap { $0.object as? NEVPNConnection }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connection in
                self?.vpnStatus = connection.status
            }
    }

    private func setupVPNManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let manager = managers?.first {
                    self.vpnManager = manager
                    self.vpnStatus = manager.connection.status
                } else {
                    self.vpnManager = NETunnelProviderManager()
                }
            }
        }
    }

    // MARK: - Actions

    func toggleVPN() {
        switch vpnStatus {
        case .connected, .connecting:
            disconnectVPN()
        case .disconnected, .invalid:
            connectVPN()
        default:
            break
        }
    }

    func connectVPN() {
        guard let manager = vpnManager,
              let config = selectedConfiguration else { return }

        // Resolve domain to IP before tunnel starts (avoids DNS-over-tunnel loop)
        let resolvedIP = Self.resolveServerAddress(config.serverAddress)

        // Configure the VPN
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = "com.argsment.Anywhere.Network-Extension"
        tunnelProtocol.serverAddress = "Anywhere"

        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = "Anywhere"
        manager.isEnabled = true

        manager.saveToPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                print("Failed to save VPN preferences: \(error.localizedDescription)")
                return
            }

            manager.loadFromPreferences { error in
                if let error {
                    print("Failed to load VPN preferences: \(error.localizedDescription)")
                    return
                }

                do {
                    var configDict = self.serializeConfiguration(config)
                    if let resolvedIP {
                        configDict["resolvedIP"] = resolvedIP
                    }
                    try manager.connection.startVPNTunnel(options: ["config": configDict as NSObject])
                } catch {
                    print("Failed to start VPN: \(error.localizedDescription)")
                }
            }
        }
    }

    func disconnectVPN() {
        vpnManager?.connection.stopVPNTunnel()
    }

    // MARK: - Configuration Switching

    /// Sends the new configuration to the running tunnel extension via app message.
    private func sendConfigurationToTunnel(_ config: VLESSConfiguration) {
        guard let session = vpnManager?.connection as? NETunnelProviderSession else { return }
        var configDict = serializeConfiguration(config)
        // Resolve domain to IP so the tunnel can use it for socket connections
        if let resolvedIP = Self.resolveServerAddress(config.serverAddress) {
            configDict["resolvedIP"] = resolvedIP
        }
        guard let data = try? JSONSerialization.data(withJSONObject: configDict) else { return }
        try? session.sendProviderMessage(data) { _ in }
    }

    // MARK: - DNS Resolution

    /// Resolves a server address to an IP string.
    /// If the address is already an IP (v4 or v6), returns it as-is.
    /// If it's a domain, resolves via `getaddrinfo` (system DNS, before tunnel is up).
    /// Returns `nil` on resolution failure.
    nonisolated static func resolveServerAddress(_ address: String) -> String? {
        // Check if already an IPv4 address
        var sa4 = sockaddr_in()
        if inet_pton(AF_INET, address, &sa4.sin_addr) == 1 { return address }

        // Check if already an IPv6 address
        var sa6 = sockaddr_in6()
        if inet_pton(AF_INET6, address, &sa6.sin6_addr) == 1 { return address }

        // Resolve domain → IP via getaddrinfo
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &result) == 0, let res = result else {
            return nil
        }
        defer { freeaddrinfo(res) }

        // Extract the first resolved IP as a string
        var current: UnsafeMutablePointer<addrinfo>? = res
        while let info = current {
            let family = info.pointee.ai_family
            if family == AF_INET {
                var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: buf)
                }
            } else if family == AF_INET6 {
                var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    return String(cString: buf)
                }
            }
            current = info.pointee.ai_next
        }

        return nil
    }

    // MARK: - Configuration Serialization

    private func serializeConfiguration(_ config: VLESSConfiguration) -> [String: Any] {
        var configDict: [String: Any] = [
            "serverAddress": config.serverAddress,
            "serverPort": config.serverPort,
            "uuid": config.uuid.uuidString,
            "encryption": config.encryption,
            "flow": config.flow ?? "",
            "security": config.security,
            "muxEnabled": config.muxEnabled,
            "xudpEnabled": config.xudpEnabled,
        ]

        // Add Reality configuration if present
        if let reality = config.reality {
            configDict["realityServerName"] = reality.serverName
            configDict["realityPublicKey"] = reality.publicKey.base64EncodedString()
            configDict["realityShortId"] = reality.shortId.map { String(format: "%02x", $0) }.joined()
            configDict["realityFingerprint"] = reality.fingerprint.rawValue
        }

        // Add TLS configuration if present
        if let tls = config.tls {
            configDict["tlsServerName"] = tls.serverName
            if let alpn = tls.alpn {
                configDict["tlsAlpn"] = alpn.joined(separator: ",")
            }
            configDict["tlsAllowInsecure"] = tls.allowInsecure
        }

        // Add transport and WebSocket configuration
        configDict["transport"] = config.transport
        if let ws = config.websocket {
            configDict["wsHost"] = ws.host
            configDict["wsPath"] = ws.path
            if !ws.headers.isEmpty {
                configDict["wsHeaders"] = ws.headers.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            }
            configDict["wsMaxEarlyData"] = ws.maxEarlyData
            configDict["wsEarlyDataHeaderName"] = ws.earlyDataHeaderName
        }

        // Add HTTP upgrade configuration
        if let hu = config.httpUpgrade {
            configDict["huHost"] = hu.host
            configDict["huPath"] = hu.path
            if !hu.headers.isEmpty {
                configDict["huHeaders"] = hu.headers.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            }
        }

        // Add XHTTP configuration
        if let xhttp = config.xhttp {
            configDict["xhttpHost"] = xhttp.host
            configDict["xhttpPath"] = xhttp.path
            configDict["xhttpMode"] = xhttp.mode.rawValue
            if !xhttp.headers.isEmpty {
                configDict["xhttpHeaders"] = xhttp.headers.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            }
            configDict["xhttpNoGRPCHeader"] = xhttp.noGRPCHeader
        }

        return configDict
    }
}
