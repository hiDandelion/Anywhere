//
//  TLS13KeyDerivation.swift
//  Anywhere
//
//  TLS 1.3 key derivation functions (RFC 8446)
//

import Foundation
import CryptoKit

/// TLS 1.3 cipher suite constants
enum TLSCipherSuite {
    static let TLS_AES_128_GCM_SHA256: UInt16 = 0x1301
    static let TLS_AES_256_GCM_SHA384: UInt16 = 0x1302
    static let TLS_CHACHA20_POLY1305_SHA256: UInt16 = 0x1303
}

/// TLS 1.3 handshake traffic keys
struct TLSHandshakeKeys {
    let clientKey: Data
    let clientIV: Data
    let serverKey: Data
    let serverIV: Data
    let clientTrafficSecret: Data
}

/// TLS 1.3 application traffic keys
struct TLSApplicationKeys {
    let clientKey: Data
    let clientIV: Data
    let serverKey: Data
    let serverIV: Data
}

/// TLS 1.3 key derivation utilities
struct TLS13KeyDerivation {
    private let cipherSuite: UInt16

    init(cipherSuite: UInt16 = TLSCipherSuite.TLS_AES_128_GCM_SHA256) {
        self.cipherSuite = cipherSuite
    }

    /// Get hash output length based on cipher suite
    var hashLength: Int {
        return cipherSuite == TLSCipherSuite.TLS_AES_256_GCM_SHA384 ? 48 : 32
    }

    /// Get encryption key length based on cipher suite
    var keyLength: Int {
        switch cipherSuite {
        case TLSCipherSuite.TLS_AES_256_GCM_SHA384:
            return 32
        default: // TLS_AES_128_GCM_SHA256
            return 16
        }
    }

    /// HKDF-Extract using appropriate hash for cipher suite
    func hkdfExtract(salt: Data, ikm: Data) -> Data {
        let saltData = salt.isEmpty ? Data(repeating: 0, count: hashLength) : salt
        let key = SymmetricKey(data: saltData)

        if cipherSuite == TLSCipherSuite.TLS_AES_256_GCM_SHA384 {
            let hmac = HMAC<SHA384>.authenticationCode(for: ikm, using: key)
            return Data(hmac)
        } else {
            let hmac = HMAC<SHA256>.authenticationCode(for: ikm, using: key)
            return Data(hmac)
        }
    }

    /// HKDF-Expand using appropriate hash for cipher suite
    func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
        let key = SymmetricKey(data: prk)
        var output = Data()
        var t = Data()
        var counter: UInt8 = 1

        while output.count < length {
            var input = t
            input.append(info)
            input.append(counter)

            if cipherSuite == TLSCipherSuite.TLS_AES_256_GCM_SHA384 {
                let hmac = HMAC<SHA384>.authenticationCode(for: input, using: key)
                t = Data(hmac)
            } else {
                let hmac = HMAC<SHA256>.authenticationCode(for: input, using: key)
                t = Data(hmac)
            }
            output.append(t)
            counter += 1
        }

        return Data(output.prefix(length))
    }

    /// HKDF-Expand-Label for TLS 1.3
    func hkdfExpandLabel(secret: Data, label: String, context: Data, length: Int) -> Data {
        let fullLabel = "tls13 " + label
        var hkdfLabel = Data()

        hkdfLabel.append(UInt8((length >> 8) & 0xFF))
        hkdfLabel.append(UInt8(length & 0xFF))
        hkdfLabel.append(UInt8(fullLabel.count))
        hkdfLabel.append(contentsOf: fullLabel.utf8)
        hkdfLabel.append(UInt8(context.count))
        hkdfLabel.append(context)

        return hkdfExpand(prk: secret, info: hkdfLabel, length: length)
    }

    /// Derive-Secret for TLS 1.3
    func deriveSecret(secret: Data, label: String, messages: Data) -> Data {
        let hashData: Data
        if cipherSuite == TLSCipherSuite.TLS_AES_256_GCM_SHA384 {
            hashData = Data(SHA384.hash(data: messages))
        } else {
            hashData = Data(SHA256.hash(data: messages))
        }
        return hkdfExpandLabel(secret: secret, label: label, context: hashData, length: hashLength)
    }

    /// Compute transcript hash
    func transcriptHash(_ messages: Data) -> Data {
        if cipherSuite == TLSCipherSuite.TLS_AES_256_GCM_SHA384 {
            return Data(SHA384.hash(data: messages))
        } else {
            return Data(SHA256.hash(data: messages))
        }
    }

    /// Derive TLS 1.3 handshake keys from shared secret
    func deriveHandshakeKeys(sharedSecret: Data, transcript: Data) -> (handshakeSecret: Data, keys: TLSHandshakeKeys) {
        // Early Secret = HKDF-Extract(salt=0, IKM=0)
        let earlySecret = hkdfExtract(salt: Data(), ikm: Data(repeating: 0, count: hashLength))

        // Derive-Secret(Early Secret, "derived", "")
        let derivedEarly = deriveSecret(secret: earlySecret, label: "derived", messages: Data())

        // Handshake Secret = HKDF-Extract(salt=derived, IKM=shared_secret)
        let handshakeSecret = hkdfExtract(salt: derivedEarly, ikm: sharedSecret)

        // client_handshake_traffic_secret
        let clientHTS = deriveSecret(secret: handshakeSecret, label: "c hs traffic", messages: transcript)
        let clientKey = hkdfExpandLabel(secret: clientHTS, label: "key", context: Data(), length: keyLength)
        let clientIV = hkdfExpandLabel(secret: clientHTS, label: "iv", context: Data(), length: 12)

        // server_handshake_traffic_secret
        let serverHTS = deriveSecret(secret: handshakeSecret, label: "s hs traffic", messages: transcript)
        let serverKey = hkdfExpandLabel(secret: serverHTS, label: "key", context: Data(), length: keyLength)
        let serverIV = hkdfExpandLabel(secret: serverHTS, label: "iv", context: Data(), length: 12)

        let keys = TLSHandshakeKeys(
            clientKey: clientKey,
            clientIV: clientIV,
            serverKey: serverKey,
            serverIV: serverIV,
            clientTrafficSecret: clientHTS
        )

        return (handshakeSecret, keys)
    }

    /// Derive application keys from the full transcript (including server Finished)
    func deriveApplicationKeys(handshakeSecret: Data, fullTranscript: Data) -> TLSApplicationKeys {
        let derivedHS = deriveSecret(secret: handshakeSecret, label: "derived", messages: Data())
        let masterSecret = hkdfExtract(salt: derivedHS, ikm: Data(repeating: 0, count: hashLength))

        // Application keys use the full transcript
        let clientATS = deriveSecret(secret: masterSecret, label: "c ap traffic", messages: fullTranscript)
        let clientKey = hkdfExpandLabel(secret: clientATS, label: "key", context: Data(), length: keyLength)
        let clientIV = hkdfExpandLabel(secret: clientATS, label: "iv", context: Data(), length: 12)

        let serverATS = deriveSecret(secret: masterSecret, label: "s ap traffic", messages: fullTranscript)
        let serverKey = hkdfExpandLabel(secret: serverATS, label: "key", context: Data(), length: keyLength)
        let serverIV = hkdfExpandLabel(secret: serverATS, label: "iv", context: Data(), length: 12)

        return TLSApplicationKeys(
            clientKey: clientKey,
            clientIV: clientIV,
            serverKey: serverKey,
            serverIV: serverIV
        )
    }

    /// Compute Client Finished verify data
    func computeFinishedVerifyData(clientTrafficSecret: Data, transcript: Data) -> Data {
        let finishedKey = hkdfExpandLabel(secret: clientTrafficSecret, label: "finished", context: Data(), length: hashLength)
        let transcriptHash = self.transcriptHash(transcript)

        let key = SymmetricKey(data: finishedKey)
        if cipherSuite == TLSCipherSuite.TLS_AES_256_GCM_SHA384 {
            let hmac = HMAC<SHA384>.authenticationCode(for: transcriptHash, using: key)
            return Data(hmac)
        } else {
            let hmac = HMAC<SHA256>.authenticationCode(for: transcriptHash, using: key)
            return Data(hmac)
        }
    }
}
