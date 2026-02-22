//
//  CPacket.h
//  Network Extension
//
//  TLS processing utilities (used by Reality/Vision).
//

#ifndef CPacket_h
#define CPacket_h

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

// MARK: - TLS Utility Functions

/// XOR nonce with sequence number for TLS 1.3 (in-place)
/// @param nonce 12-byte nonce buffer (modified in place)
/// @param seqNum 64-bit sequence number
void xor_nonce_with_seq(uint8_t *nonce, uint64_t seqNum);

/// Copy payload to packet buffer
/// @param dst Destination buffer
/// @param src Source data
/// @param length Number of bytes to copy
void copy_payload(uint8_t *dst, const uint8_t *src, size_t length);

/// Parse TLS record header from buffer
/// @param buffer Input buffer
/// @param bufferLen Buffer length
/// @param outContentType Output: content type (0x17 = app data, 0x15 = alert)
/// @param outRecordLen Output: record body length
/// @return 1 if header parsed successfully, 0 if need more data
int parse_tls_header(const uint8_t *buffer, size_t bufferLen,
                     uint8_t *outContentType, uint16_t *outRecordLen);

/// Find content end in TLS 1.3 decrypted inner plaintext
/// TLS 1.3 format: [content][content_type][padding zeros]
/// @param data Decrypted data
/// @param length Data length
/// @param outContentType Output: inner content type byte
/// @return Index of last content byte (before content type), or -1 if invalid
ssize_t find_tls13_content_end(const uint8_t *data, size_t length, uint8_t *outContentType);

/// Strip TLS 1.3 padding and content type, return content length
/// @param data Decrypted data (will NOT be modified)
/// @param length Data length
/// @param outContentType Output: inner content type (0x17 = app data, 0x16 = handshake)
/// @return Content length (excluding type and padding), or -1 if invalid
ssize_t tls13_unwrap_content(const uint8_t *data, size_t length, uint8_t *outContentType);

#endif /* CPacket_h */
