//
//  ConfigurationEditorView.swift
//  Anywhere
//
//  SwiftUI form for adding/editing VLESS configurations
//

import SwiftUI

struct ConfigurationEditorView: View {
    let existingConfiguration: VLESSConfiguration?
    let onSave: (VLESSConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var serverAddress = ""
    @State private var serverPort = ""
    @State private var uuid = ""
    @State private var encryption = "none"
    @State private var transport = "tcp"
    @State private var flow = ""
    @State private var security = "none"
    
    // XHTTP fields
    @State private var xhttpHost = ""
    @State private var xhttpPath = "/"
    @State private var xhttpMode = "auto"

    // TLS fields
    @State private var tlsSNI = ""
    @State private var tlsALPN = ""
    @State private var tlsAllowInsecure = false

    // Mux + XUDP
    @State private var muxEnabled = true
    @State private var xudpEnabled = true

    // Reality fields
    @State private var sni = ""
    @State private var publicKey = ""
    @State private var shortId = ""
    @State private var fingerprint: TLSFingerprint = .chrome120

    private var isReality: Bool { security == "reality" }
    private var isTLS: Bool { security == "tls" }

    private var isValid: Bool {
        !name.isEmpty &&
        !serverAddress.isEmpty &&
        UInt16(serverPort) != nil &&
        UUID(uuidString: uuid) != nil &&
        (!isReality || (!sni.isEmpty && !publicKey.isEmpty))
    }

    init(existingConfiguration: VLESSConfiguration? = nil, onSave: @escaping (VLESSConfiguration) -> Void) {
        self.existingConfiguration = existingConfiguration
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                
                Section("Server") {
                    TextField("Server Address", text: $serverAddress)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $serverPort)
                        .keyboardType(.numberPad)
                    TextField("UUID", text: $uuid)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Encryption", selection: $encryption) {
                        Text("None").tag("none")
                    }
                }
                
                Section("Transport") {
                    Picker("Transport", selection: $transport) {
                        Text("TCP").tag("tcp")
                        Text("WebSocket").tag("ws")
                        Text("HTTPUpgrade").tag("httpupgrade")
                        Text("XHTTP").tag("xhttp")
                    }
                    .onChange(of: transport) {
                        if flow != "" && transport != "tcp" {
                            flow = ""
                        }
                    }
                    if transport == "xhttp" {
                        TextField("Host", text: $xhttpHost, prompt: Text("Server address"))
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Path", text: $xhttpPath, prompt: Text("/"))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Picker("Mode", selection: $xhttpMode) {
                            Text("Auto").tag("auto")
                            Text("Packet Up").tag("packet-up")
                            Text("Stream One").tag("stream-one")
                        }
                    }
                    if transport == "tcp" {
                        Picker("Flow", selection: $flow) {
                            Text("None").tag("")
                            Text("Vision").tag("xtls-rprx-vision")
                            Text("Vision with UDP 443").tag("xtls-rprx-vision-udp443")
                        }
                        Toggle("Mux", isOn: $muxEnabled)
                            .onChange(of: muxEnabled) {
                                if muxEnabled == false {
                                    xudpEnabled = false
                                }
                            }
                        if muxEnabled {
                            Toggle("XUDP", isOn: $xudpEnabled)
                        }
                    }
                }
                
                Section("TLS") {
                    Picker("Security", selection: $security) {
                        Text("None").tag("none")
                        Text("TLS").tag("tls")
                        Text("Reality").tag("reality")
                    }
                    if isTLS {
                        TextField("SNI", text: $tlsSNI, prompt: Text("Server address"))
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("ALPN", text: $tlsALPN, prompt: Text("h2,http/1.1"))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Toggle("Allow Insecure", isOn: $tlsAllowInsecure)
                    }
                    if isReality {
                        TextField("SNI", text: $sni)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Public Key", text: $publicKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Short ID", text: $shortId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Picker("Fingerprint", selection: $fingerprint) {
                            ForEach(TLSFingerprint.allCases, id: \.self) { fp in
                                Text(fp.displayName).tag(fp)
                            }
                        }
                    }
                }
            }
            .navigationTitle(existingConfiguration != nil ? "Edit Configuration" : "Add Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26.0, *) {
                        Button(role: .cancel) {
                            dismiss()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    }
                    else {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if #available(iOS 26.0, *) {
                        Button(role: .confirm) {
                            save()
                        } label: {
                            Label("Save", systemImage: "checkmark")
                        }
                        .disabled(!isValid)
                    }
                    else {
                        Button("Save") {
                            save()
                        }
                        .disabled(!isValid)
                    }
                }
            }
        }
        .onAppear { populateFromExisting() }
    }

    private func populateFromExisting() {
        guard let config = existingConfiguration else { return }
        name = config.name
        serverAddress = config.serverAddress
        serverPort = String(config.serverPort)
        uuid = config.uuid.uuidString
        encryption = config.encryption
        transport = config.transport
        flow = config.flow ?? ""
        security = config.security

        if let xhttp = config.xhttp {
            xhttpHost = xhttp.host
            xhttpPath = xhttp.path
            xhttpMode = xhttp.mode.rawValue
        }

        muxEnabled = config.muxEnabled
        xudpEnabled = config.xudpEnabled

        if let tls = config.tls {
            tlsSNI = tls.serverName
            tlsALPN = tls.alpn?.joined(separator: ",") ?? ""
            tlsAllowInsecure = tls.allowInsecure
        }
        
        if let reality = config.reality {
            sni = reality.serverName
            publicKey = reality.publicKey.base64URLEncodedString()
            shortId = reality.shortId.hexEncodedString()
            fingerprint = reality.fingerprint
        }
    }

    private func save() {
        guard let port = UInt16(serverPort),
              let parsedUUID = UUID(uuidString: uuid) else { return }

        var realityConfig: RealityConfiguration?
        if isReality {
            guard let pk = Data(base64URLEncoded: publicKey) else { return }
            let sid = Data(hexString: shortId) ?? Data()
            realityConfig = RealityConfiguration(
                serverName: sni,
                publicKey: pk,
                shortId: sid,
                fingerprint: fingerprint
            )
        }

        var tlsConfig: TLSConfiguration?
        if isTLS {
            let sni = tlsSNI.isEmpty ? serverAddress : tlsSNI
            let alpn: [String]? = tlsALPN.isEmpty ? nil : tlsALPN.split(separator: ",").map { String($0) }
            tlsConfig = TLSConfiguration(
                serverName: sni,
                alpn: alpn,
                allowInsecure: tlsAllowInsecure
            )
        }

        var xhttpConfig: XHTTPConfiguration?
        if transport == "xhttp" {
            let host = xhttpHost.isEmpty ? serverAddress : xhttpHost
            let mode = XHTTPMode(rawValue: xhttpMode) ?? .auto
            xhttpConfig = XHTTPConfiguration(host: host, path: xhttpPath, mode: mode)
        }

        let config = VLESSConfiguration(
            id: existingConfiguration?.id ?? UUID(),
            name: name,
            serverAddress: serverAddress,
            serverPort: port,
            uuid: parsedUUID,
            encryption: encryption,
            transport: transport,
            flow: flow.isEmpty ? nil : flow,
            security: security,
            tls: tlsConfig,
            reality: realityConfig,
            xhttp: xhttpConfig,
            muxEnabled: muxEnabled,
            xudpEnabled: xudpEnabled
        )

        onSave(config)
        dismiss()
    }
}
