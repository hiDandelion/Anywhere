//
//  TLSRecordCrypto.swift
//  Anywhere
//
//  TLS 1.3 record layer encryption/decryption
//

import Foundation
import CryptoKit

/// TLS 1.3 record layer cryptographic operations
struct TLSRecordCrypto {
    /// Build nonce for TLS 1.3 record encryption/decryption
    /// The sequence number is XOR'd with the last 8 bytes of the 12-byte IV
    static func buildNonce(iv: Data, seqNum: UInt64) -> Data {
        var nonce = iv
        for i in 0..<8 {
            nonce[nonce.count - 8 + i] ^= UInt8((seqNum >> (56 - i * 8)) & 0xFF)
        }
        return nonce
    }

    /// Encrypt a TLS 1.3 handshake record using AES-GCM
    static func encryptHandshakeRecord(plaintext: Data, key: Data, iv: Data, seqNum: UInt64) throws -> Data {
        let nonce = buildNonce(iv: iv, seqNum: seqNum)

        // The plaintext includes the real content type at the end
        var innerPlaintext = plaintext
        innerPlaintext.append(0x16) // Handshake content type

        // AAD: record header
        let len = UInt16(innerPlaintext.count + 16)
        var aad = Data()
        aad.append(0x17) // Application Data (outer type)
        aad.append(0x03)
        aad.append(0x03)
        aad.append(UInt8(len >> 8))
        aad.append(UInt8(len & 0xFF))

        // Encrypt
        let symmetricKey = SymmetricKey(data: key)
        let nonceObj = try AES.GCM.Nonce(data: nonce)
        let sealedBox = try AES.GCM.seal(innerPlaintext, using: symmetricKey, nonce: nonceObj, authenticating: aad)

        var result = Data(sealedBox.ciphertext)
        result.append(contentsOf: sealedBox.tag)
        return result
    }

    /// Decrypt a TLS 1.3 record using AES-GCM
    static func decryptRecord(ciphertext: Data, key: Data, iv: Data, seqNum: UInt64, recordHeader: Data) throws -> Data {
        let nonce = buildNonce(iv: iv, seqNum: seqNum)

        let symmetricKey = SymmetricKey(data: key)
        let nonceObj = try AES.GCM.Nonce(data: nonce)

        guard ciphertext.count >= 16 else {
            throw TLSRecordError.ciphertextTooShort
        }

        let ct = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)

        let sealedBox = try AES.GCM.SealedBox(nonce: nonceObj, ciphertext: ct, tag: tag)
        let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: recordHeader)

        // TLS 1.3 inner plaintext: content + contentType + zeros (padding)
        // Find the last non-zero byte (the content type) and remove it along with padding
        guard !decrypted.isEmpty else {
            throw TLSRecordError.emptyDecryptedData
        }

        // Find last non-zero byte (content type)
        var contentEnd = decrypted.count - 1
        while contentEnd >= 0 && decrypted[contentEnd] == 0 {
            contentEnd -= 1
        }

        guard contentEnd >= 0 else {
            throw TLSRecordError.noContentTypeFound
        }

        // contentEnd now points to the content type byte, return everything before it
        return Data(decrypted.prefix(contentEnd))
    }

    /// Encrypt using AES-GCM (returns ciphertext + tag)
    static func encryptAESGCM(plaintext: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonceObj = try AES.GCM.Nonce(data: nonce)

        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonceObj, authenticating: aad)

        // Return ciphertext + tag
        var result = Data(sealedBox.ciphertext)
        result.append(contentsOf: sealedBox.tag)
        return result
    }
}

/// Errors from TLS record operations
enum TLSRecordError: Error, LocalizedError {
    case ciphertextTooShort
    case emptyDecryptedData
    case noContentTypeFound

    var errorDescription: String? {
        switch self {
        case .ciphertextTooShort:
            return "Ciphertext too short for decryption"
        case .emptyDecryptedData:
            return "Empty decrypted data"
        case .noContentTypeFound:
            return "No content type found in decrypted data"
        }
    }
}
