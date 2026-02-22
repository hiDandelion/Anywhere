//
//  CPacket.c
//  Network Extension
//
//  TLS processing utilities (used by Reality/Vision).
//

#include "CPacket.h"
#include <string.h>

// MARK: - TLS Utility Functions

void xor_nonce_with_seq(uint8_t *nonce, uint64_t seqNum) {
    // XOR last 8 bytes of nonce with sequence number (big-endian)
    nonce[4]  ^= (uint8_t)(seqNum >> 56);
    nonce[5]  ^= (uint8_t)(seqNum >> 48);
    nonce[6]  ^= (uint8_t)(seqNum >> 40);
    nonce[7]  ^= (uint8_t)(seqNum >> 32);
    nonce[8]  ^= (uint8_t)(seqNum >> 24);
    nonce[9]  ^= (uint8_t)(seqNum >> 16);
    nonce[10] ^= (uint8_t)(seqNum >> 8);
    nonce[11] ^= (uint8_t)(seqNum);
}

void copy_payload(uint8_t *dst, const uint8_t *src, size_t length) {
    memcpy(dst, src, length);
}

int parse_tls_header(const uint8_t *buffer, size_t bufferLen,
                     uint8_t *outContentType, uint16_t *outRecordLen) {
    if (bufferLen < 5) {
        return 0;
    }
    *outContentType = buffer[0];
    *outRecordLen = ((uint16_t)buffer[3] << 8) | buffer[4];
    return 1;
}

ssize_t find_tls13_content_end(const uint8_t *data, size_t length, uint8_t *outContentType) {
    if (length == 0) {
        return -1;
    }

    // Scan backwards to find last non-zero byte (content type)
    ssize_t i = (ssize_t)length - 1;

    // Fast path: check last byte (common case: no padding or minimal padding)
    if (length >= 8) {
        const uint8_t *end = data + length;
        if (end[-1] != 0) {
            *outContentType = end[-1];
            return (ssize_t)length - 1;
        }
    }

    // Scan backwards for non-zero
    while (i >= 0 && data[i] == 0) {
        i--;
    }

    if (i < 0) {
        return -1;  // All zeros, invalid
    }

    *outContentType = data[i];
    return i;
}

ssize_t tls13_unwrap_content(const uint8_t *data, size_t length, uint8_t *outContentType) {
    if (length == 0) {
        return -1;
    }

    ssize_t contentEnd = find_tls13_content_end(data, length, outContentType);
    if (contentEnd < 0) {
        return -1;
    }

    // contentEnd points to the content type byte, return length before it
    return contentEnd;
}
