//
//  LWIPUDPFlow.swift
//  Network Extension
//
//  Bridges UDP datagrams between lwIP and a VLESS proxy connection.
//  One instance per UDP flow (5-tuple).
//
//  When a MuxManager is available (Vision flow active), UDP flows are
//  multiplexed through a shared VLESS mux connection. Otherwise, each
//  flow gets its own VLESSClient UDP connection.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.argsment.Anywhere.Network-Extension", category: "LWIP-UDP")

class LWIPUDPFlow {
    let flowKey: String
    let srcHost: String
    let srcPort: UInt16
    let dstHost: String
    let dstPort: UInt16
    let isIPv6: Bool
    let configuration: VLESSConfiguration
    let lwipQueue: DispatchQueue

    // Raw IP bytes for lwip_bridge_udp_sendto (swapped src/dst for responses)
    let srcIPBytes: Data  // original source (becomes dst in response)
    let dstIPBytes: Data  // original destination (becomes src in response)

    var lastActivity: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    // Non-mux path
    private var vlessClient: VLESSClient?
    private var vlessConnection: VLESSConnection?

    // Mux path
    private var muxSession: MuxSession?

    private var vlessConnecting = false
    private var pendingData: [Data] = []  // raw payloads for mux, length-framed chunks for non-mux
    private var pendingIsMux = false       // tracks which format pendingData uses
    private var closed = false

    init(flowKey: String,
         srcHost: String, srcPort: UInt16,
         dstHost: String, dstPort: UInt16,
         srcIPData: Data, dstIPData: Data,
         isIPv6: Bool,
         configuration: VLESSConfiguration,
         lwipQueue: DispatchQueue) {
        self.flowKey = flowKey
        self.srcHost = srcHost
        self.srcPort = srcPort
        self.dstHost = dstHost
        self.dstPort = dstPort
        self.srcIPBytes = srcIPData
        self.dstIPBytes = dstIPData
        self.isIPv6 = isIPv6
        self.configuration = configuration
        self.lwipQueue = lwipQueue
    }

    // MARK: - Data Handling (called on lwipQueue)

    func handleReceivedData(_ data: Data, payloadLength: Int) {
        guard !closed else { return }
        lastActivity = CFAbsoluteTimeGetCurrent()

        let payload = data.prefix(payloadLength)

        // Mux path: send raw payload (mux framing handled by MuxSession)
        if let session = muxSession {
            session.send(data: Data(payload)) { [weak self] error in
                if let error {
                    logger.error("[UDP] Mux send error for \(self?.flowKey ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        // Non-mux path: send length-framed payload through VLESS connection
        if let conn = vlessConnection {
            sendUDPThroughVLESS(conn: conn, payload: data, payloadLength: payloadLength)
            return
        }

        // Buffer and connect
        if vlessConnecting {
            bufferPayload(data: data, payloadLength: payloadLength)
        } else {
            bufferPayload(data: data, payloadLength: payloadLength)
            connectVLESS()
        }
    }

    private func bufferPayload(data: Data, payloadLength: Int) {
        if LWIPStack.shared?.muxManager != nil {
            // Mux path: buffer raw payloads
            pendingIsMux = true
            pendingData.append(Data(data.prefix(payloadLength)))
        } else {
            // Non-mux path: buffer length-framed
            pendingIsMux = false
            var framedPayload = Data(capacity: 2 + payloadLength)
            framedPayload.append(UInt8(payloadLength >> 8))
            framedPayload.append(UInt8(payloadLength & 0xFF))
            framedPayload.append(data)
            pendingData.append(framedPayload)
        }
    }

    private func sendUDPThroughVLESS(conn: VLESSConnection, payload: Data, payloadLength: Int) {
        var framedPayload = Data(capacity: 2 + payloadLength)
        framedPayload.append(UInt8(payloadLength >> 8))
        framedPayload.append(UInt8(payloadLength & 0xFF))
        framedPayload.append(payload)

        conn.sendRaw(data: framedPayload) { [weak self] error in
            if let error {
                logger.error("[UDP] VLESS send error for \(self?.flowKey ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - VLESS Connection

    private func connectVLESS() {
        guard !vlessConnecting && vlessConnection == nil && muxSession == nil && !closed else { return }
        vlessConnecting = true

        if let muxManager = LWIPStack.shared?.muxManager {
            // Mux path
            // Cone NAT: GlobalID = blake3("udp:srcHost:srcPort") matching Xray-core's
            // net.Destination.String() format. Non-zero GlobalID enables server-side
            // session persistence (Full Cone NAT). Nil = no GlobalID (Symmetric NAT).
            let globalID = configuration.xudpEnabled ? XUDP.generateGlobalID(sourceAddress: "udp:\(srcHost):\(srcPort)") : nil
            muxManager.dispatch(network: .udp, host: dstHost, port: dstPort, globalID: globalID) { [weak self] result in
                guard let self else { return }

                self.lwipQueue.async {
                    self.vlessConnecting = false
                    guard !self.closed else { return }

                    switch result {
                    case .success(let session):
                        self.muxSession = session

                        // Set up receive handler
                        session.dataHandler = { [weak self] data in
                            self?.handleVLESSData(data)
                        }
                        session.closeHandler = { [weak self] in
                            guard let self else { return }
                            self.lwipQueue.async {
                                self.close()
                                LWIPStack.shared?.udpFlows.removeValue(forKey: self.flowKey)
                            }
                        }

                        // Send buffered raw payloads
                        let buffered = self.pendingData
                        self.pendingData.removeAll()
                        for payload in buffered {
                            session.send(data: payload) { [weak self] error in
                                if let error {
                                    logger.error("[UDP] Mux initial send error for \(self?.flowKey ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }

                    case .failure(let error):
                        if case .dropped = error as? VLESSError {} else {
                            logger.error("[UDP] Mux dispatch failed: \(self.flowKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                        self.releaseVLESS()
                        LWIPStack.shared?.udpFlows.removeValue(forKey: self.flowKey)
                    }
                }
            }
        } else {
            // Non-mux path (existing behavior)
            let client = VLESSClient(configuration: configuration)

            client.connectUDP(to: dstHost, port: dstPort) { [weak self] result in
                guard let self else { return }

                self.lwipQueue.async {
                    self.vlessConnecting = false
                    guard !self.closed else { return }

                    switch result {
                    case .success(let vlessConnection):
                        self.vlessClient = client
                        self.vlessConnection = vlessConnection

                        // Send buffered length-framed data
                        if !self.pendingData.isEmpty {
                            var dataToSend = Data()
                            for chunk in self.pendingData {
                                dataToSend.append(chunk)
                            }
                            self.pendingData.removeAll()
                            // Use sendRaw because pendingData is already length-framed
                            vlessConnection.sendRaw(data: dataToSend) { [weak self] error in
                                if let error {
                                    logger.error("[UDP] VLESS initial send error for \(self?.flowKey ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }

                        // Start receiving VLESS responses
                        self.startVLESSReceiving(vlessConnection: vlessConnection)

                    case .failure(let error):
                        if case .dropped = error as? VLESSError {} else {
                            logger.error("[UDP] connect failed: \(self.flowKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                        self.releaseVLESS()
                        LWIPStack.shared?.udpFlows.removeValue(forKey: self.flowKey)
                    }
                }
            }
        }
    }

    private func startVLESSReceiving(vlessConnection: VLESSConnection) {
        vlessConnection.startReceiving { [weak self] data in
            guard let self else { return }
            self.handleVLESSData(data)
        } errorHandler: { [weak self] error in
            guard let self else { return }
            if let error {
                logger.error("[UDP] VLESS recv error: \(self.flowKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            self.lwipQueue.async {
                self.close()
                LWIPStack.shared?.udpFlows.removeValue(forKey: self.flowKey)
            }
        }
    }

    private func handleVLESSData(_ data: Data) {
        lwipQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.lastActivity = CFAbsoluteTimeGetCurrent()

            // Send UDP response via lwIP (swap src/dst for the response packet)
            self.dstIPBytes.withUnsafeBytes { dstPtr in  // original dst = response src
                self.srcIPBytes.withUnsafeBytes { srcPtr in  // original src = response dst
                    data.withUnsafeBytes { dataPtr in
                        guard let dstBase = dstPtr.baseAddress,
                              let srcBase = srcPtr.baseAddress,
                              let dataBase = dataPtr.baseAddress else {
                            logger.error("[UDP] NULL base address in data pointers")
                            return
                        }
                        lwip_bridge_udp_sendto(
                            dstBase, self.dstPort,   // response source = original destination
                            srcBase, self.srcPort,   // response destination = original source
                            self.isIPv6 ? 1 : 0,
                            dataBase, Int32(data.count)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Close

    func close() {
        guard !closed else { return }
        closed = true
        releaseVLESS()
    }

    private func releaseVLESS() {
        let conn = vlessConnection
        let client = vlessClient
        let session = muxSession
        vlessConnection = nil
        vlessClient = nil
        muxSession = nil
        vlessConnecting = false
        pendingData.removeAll()
        conn?.cancel()
        client?.cancel()
        session?.close()
    }

    deinit {
        vlessConnection?.cancel()
        vlessClient?.cancel()
        muxSession?.close()
    }
}
