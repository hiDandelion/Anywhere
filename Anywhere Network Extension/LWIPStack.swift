//
//  LWIPStack.swift
//  Anywhere
//
//  Created by Junhui Lou on 1/26/26.
//

import Foundation
import NetworkExtension
import os.log

private let logger = Logger(subsystem: "com.argsment.Anywhere.Network-Extension", category: "LWIPStack")

// MARK: - LWIPStack

/// Main coordinator for the lwIP TCP/IP stack.
///
/// All lwIP calls run on a single serial `DispatchQueue` (`lwipQueue`).
/// One instance per Network Extension process, accessible via ``shared``.
///
/// Reads IP packets from the tunnel's `NEPacketTunnelFlow`, feeds them into
/// lwIP for TCP/UDP reassembly, and dispatches resulting connections through
/// VLESS proxy clients. Response data is written back to the packet flow.
class LWIPStack {

    // MARK: Properties

    /// Serial queue for all lwIP operations (lwIP is not thread-safe).
    let lwipQueue = DispatchQueue(label: "com.argsment.Anywhere.lwip")

    /// Queue for writing packets back to the tunnel.
    private let outputQueue = DispatchQueue(label: "com.argsment.Anywhere.output")

    private var packetFlow: NEPacketTunnelFlow?
    private(set) var configuration: VLESSConfiguration?
    private(set) var ipv6Enabled: Bool = false
    private var running = false

    // lwIP periodic timeout timer
    private var timeoutTimer: DispatchSourceTimer?

    /// Mux manager for multiplexing UDP flows (created when Vision flow is active).
    var muxManager: MuxManager?

    /// Active UDP flows keyed by 5-tuple string (e.g. "10.0.0.1:1234-8.8.8.8:53").
    var udpFlows: [String: LWIPUDPFlow] = [:]
    private var udpCleanupTimer: DispatchSourceTimer?
    private let maxUDPFlows = 200
    private let udpIdleTimeout: CFAbsoluteTime = 60

    /// Singleton for C callback access (one NE process = one stack).
    static var shared: LWIPStack?

    // MARK: - Lifecycle

    /// Starts the lwIP stack and begins reading packets from the tunnel.
    ///
    /// - Parameters:
    ///   - packetFlow: The tunnel's packet flow for reading/writing IP packets.
    ///   - configuration: The VLESS proxy configuration.
    func start(packetFlow: NEPacketTunnelFlow,
               configuration: VLESSConfiguration,
               ipv6Enabled: Bool = false) {
        logger.info("[LWIPStack] Starting, ipv6Enabled=\(ipv6Enabled)")
        LWIPStack.shared = self
        self.packetFlow = packetFlow
        self.configuration = configuration
        self.ipv6Enabled = ipv6Enabled

        lwipQueue.async { [self] in
            self.running = true

            // Create MuxManager when Vision + Mux is active (matches Xray-core auto-mux for UDP)
            if configuration.muxEnabled && (configuration.flow == "xtls-rprx-vision" || configuration.flow == "xtls-rprx-vision-udp443") {
                self.muxManager = MuxManager(configuration: configuration, lwipQueue: self.lwipQueue)
            }

            self.registerCallbacks()
            lwip_bridge_init()
            self.startTimeoutTimer()
            self.startUDPCleanupTimer()
            self.startReadingPackets()
            logger.info("[LWIPStack] Started, mux=\(self.muxManager != nil), ready for packets")
        }
    }

    /// Stops the lwIP stack and closes all active flows.
    func stop() {
        logger.info("[LWIPStack] Stopping")
        lwipQueue.sync { [self] in
            self.shutdownInternal()
        }

        self.packetFlow = nil
        self.configuration = nil
        LWIPStack.shared = nil
    }

    /// Switches to a new configuration, tearing down all active connections.
    ///
    /// Shuts down the lwIP stack and all VLESS connections, then restarts
    /// with the new configuration using the existing packet flow.
    func switchConfiguration(_ newConfiguration: VLESSConfiguration, ipv6Enabled: Bool? = nil) {
        logger.info("[LWIPStack] Switching configuration")
        lwipQueue.async { [self] in
            self.shutdownInternal()

            self.configuration = newConfiguration
            if let ipv6Enabled {
                self.ipv6Enabled = ipv6Enabled
            }

            self.running = true

            // Recreate MuxManager with new config
            if newConfiguration.muxEnabled && (newConfiguration.flow == "xtls-rprx-vision" || newConfiguration.flow == "xtls-rprx-vision-udp443") {
                self.muxManager = MuxManager(configuration: newConfiguration, lwipQueue: self.lwipQueue)
            }

            self.registerCallbacks()
            lwip_bridge_init()
            self.startTimeoutTimer()
            self.startUDPCleanupTimer()
            self.startReadingPackets()
            logger.info("[LWIPStack] Switched to new configuration, mux=\(self.muxManager != nil), ready for packets")
        }
    }

    /// Shuts down the lwIP stack and all active flows. Must be called on `lwipQueue`.
    private func shutdownInternal() {
        self.running = false

        self.timeoutTimer?.cancel()
        self.timeoutTimer = nil
        self.udpCleanupTimer?.cancel()
        self.udpCleanupTimer = nil

        self.muxManager?.closeAll()
        self.muxManager = nil

        let flowCount = self.udpFlows.count
        for (_, flow) in self.udpFlows {
            flow.close()
        }
        self.udpFlows.removeAll()

        lwip_bridge_shutdown()
        logger.info("[LWIPStack] Shutdown complete, closed \(flowCount) UDP flows")
    }

    // MARK: - Callback Registration

    /// Registers C callbacks that route lwIP events through ``shared``.
    private func registerCallbacks() {
        // Output: lwIP → tunnel packet flow
        lwip_bridge_set_output_fn { data, len, isIPv6 in
            guard let shared = LWIPStack.shared, let data else { return }
            let packetData = Data(bytes: data, count: Int(len))
            let proto = isIPv6 != 0 ? NSNumber(value: AF_INET6) : NSNumber(value: AF_INET)
            shared.outputQueue.async {
                shared.packetFlow?.writePackets([packetData], withProtocols: [proto])
            }
        }

        // TCP accept: create a new LWIPTCPConnection for each incoming connection
        lwip_bridge_set_tcp_accept_fn { srcIP, srcPort, dstIP, dstPort, isIPv6, pcb in
            guard let shared = LWIPStack.shared,
                  let pcb, let dstIP,
                  let config = shared.configuration else {
                logger.error("[LWIPStack] tcp_accept: guard failed")
                return nil
            }

            if isIPv6 != 0 && !shared.ipv6Enabled {
                logger.debug("[LWIPStack] tcp_accept: dropping IPv6 connection (IPv6 disabled)")
                return nil
            }

            let dstHost = LWIPStack.ipAddrToString(dstIP, isIPv6: isIPv6 != 0)
            let conn = LWIPTCPConnection(pcb: pcb, dstHost: dstHost, dstPort: dstPort,
                                          configuration: config, lwipQueue: shared.lwipQueue)
            return Unmanaged.passRetained(conn).toOpaque()
        }

        // TCP recv: deliver data to the connection
        lwip_bridge_set_tcp_recv_fn { conn, data, len in
            guard let conn else {
                logger.error("[LWIPStack] tcp_recv: conn is nil")
                return
            }
            let tcpConn = Unmanaged<LWIPTCPConnection>.fromOpaque(conn).takeUnretainedValue()
            if let data, len > 0 {
                tcpConn.handleReceivedData(Data(bytes: data, count: Int(len)))
            } else {
                tcpConn.handleRemoteClose()
            }
        }

        // TCP sent: notify the connection of acknowledged bytes
        lwip_bridge_set_tcp_sent_fn { conn, len in
            guard let conn else { return }
            let tcpConn = Unmanaged<LWIPTCPConnection>.fromOpaque(conn).takeUnretainedValue()
            tcpConn.handleSent(len: len)
        }

        // TCP error: PCB is already freed by lwIP — release our reference
        lwip_bridge_set_tcp_err_fn { conn, err in
            guard let conn else {
                logger.error("[LWIPStack] tcp_err: conn is nil, err=\(err)")
                return
            }
            let tcpConn = Unmanaged<LWIPTCPConnection>.fromOpaque(conn).takeRetainedValue()
            tcpConn.handleError(err: err)
        }

        // UDP recv: route datagrams to per-flow handlers
        lwip_bridge_set_udp_recv_fn { srcIP, srcPort, dstIP, dstPort, isIPv6, data, len in
            guard let shared = LWIPStack.shared,
                  let srcIP, let dstIP, let data else { return }

            if isIPv6 != 0 && !shared.ipv6Enabled {
                logger.debug("[LWIPStack] udp_recv: dropping IPv6 packet (IPv6 disabled)")
                return
            }

            let payload = Data(bytes: data, count: Int(len))
            let srcHost = LWIPStack.ipAddrToString(srcIP, isIPv6: isIPv6 != 0)
            let dstHost = LWIPStack.ipAddrToString(dstIP, isIPv6: isIPv6 != 0)
            let flowKey = "\(srcHost):\(srcPort)-\(dstHost):\(dstPort)"

            if let flow = shared.udpFlows[flowKey] {
                flow.handleReceivedData(payload, payloadLength: Int(len))
                return
            }

            guard shared.udpFlows.count < shared.maxUDPFlows else {
                logger.error("[LWIPStack] UDP max flows reached (\(shared.maxUDPFlows)), dropping \(flowKey, privacy: .public)")
                return
            }
            guard let config = shared.configuration else { return }

            let addrSize = isIPv6 != 0 ? 16 : 4
            let srcIPData = Data(bytes: srcIP, count: addrSize)
            let dstIPData = Data(bytes: dstIP, count: addrSize)

            let flow = LWIPUDPFlow(
                flowKey: flowKey,
                srcHost: srcHost, srcPort: srcPort,
                dstHost: dstHost, dstPort: dstPort,
                srcIPData: srcIPData, dstIPData: dstIPData,
                isIPv6: isIPv6 != 0,
                configuration: config,
                lwipQueue: shared.lwipQueue
            )
            shared.udpFlows[flowKey] = flow
            flow.handleReceivedData(payload, payloadLength: Int(len))
        }
    }

    // MARK: - Packet Reading

    /// Continuously reads IP packets from the tunnel and feeds them into lwIP.
    private func startReadingPackets() {
        packetFlow?.readPackets { [weak self] packets, protocols in
            guard let self, self.running else { return }

            self.lwipQueue.async {
                for i in 0..<packets.count {
                    packets[i].withUnsafeBytes { buffer in
                        guard let baseAddress = buffer.baseAddress else { return }
                        lwip_bridge_input(baseAddress, Int32(buffer.count))
                    }
                }
            }

            self.startReadingPackets()
        }
    }

    // MARK: - Timers

    /// Starts the lwIP periodic timeout timer (250ms interval).
    private func startTimeoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: lwipQueue)
        timer.schedule(deadline: .now() + .milliseconds(250),
                       repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            lwip_bridge_check_timeouts()
        }
        timer.resume()
        timeoutTimer = timer
    }

    /// Starts the UDP flow cleanup timer (1-second interval, 60-second idle timeout).
    private func startUDPCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: lwipQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = CFAbsoluteTimeGetCurrent()
            var keysToRemove: [String] = []
            for (key, flow) in self.udpFlows {
                if now - flow.lastActivity > self.udpIdleTimeout {
                    flow.close()
                    keysToRemove.append(key)
                }
            }
            for key in keysToRemove {
                self.udpFlows.removeValue(forKey: key)
            }
        }
        timer.resume()
        udpCleanupTimer = timer
    }

    // MARK: - IP Address Helpers

    /// Converts a raw IP address pointer to a human-readable string.
    ///
    /// - Parameters:
    ///   - addr: Pointer to the raw IP address bytes (4 bytes for IPv4, 16 bytes for IPv6).
    ///   - isIPv6: Whether the address is IPv6.
    /// - Returns: A string representation (e.g. "192.168.1.1" or "2001:db8::1").
    static func ipAddrToString(_ addr: UnsafeRawPointer, isIPv6: Bool) -> String {
        if isIPv6 {
            let u32Ptr = addr.assumingMemoryBound(to: UInt32.self)
            var bytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<4 {
                let val = u32Ptr[i]
                bytes[i * 4 + 0] = UInt8((val >> 0) & 0xFF)
                bytes[i * 4 + 1] = UInt8((val >> 8) & 0xFF)
                bytes[i * 4 + 2] = UInt8((val >> 16) & 0xFF)
                bytes[i * 4 + 3] = UInt8((val >> 24) & 0xFF)
            }
            var parts = [String]()
            for i in stride(from: 0, to: 16, by: 2) {
                let val = UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
                parts.append(String(val, radix: 16))
            }
            return parts.joined(separator: ":")
        } else {
            let bytes = addr.assumingMemoryBound(to: UInt8.self)
            return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
        }
    }
}
