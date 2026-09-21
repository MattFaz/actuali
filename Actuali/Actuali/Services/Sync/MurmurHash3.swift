// Actuali/Actuali/Services/Sync/MurmurHash3.swift

import Foundation

/// MurmurHash3 implementation matching the JS murmurhash package (v3, seed=0)
/// Used for CRDT Merkle tree hashing
enum MurmurHash3 {
    /// Hash a string using MurmurHash3 (32-bit, x86)
    /// - Parameters:
    ///   - key: The string to hash
    ///   - seed: The seed value (default 0, matching JS library)
    /// - Returns: 32-bit hash value
    static func hash(_ key: String, seed: UInt32 = 0) -> UInt32 {
        let data = Array(key.utf8)
        return hash(data, seed: seed)
    }

    /// Hash bytes using MurmurHash3 (32-bit, x86)
    static func hash(_ key: [UInt8], seed: UInt32 = 0) -> UInt32 {
        let length = key.count
        var h1 = seed

        let c1: UInt32 = 0xcc9e2d51
        let c2: UInt32 = 0x1b873593

        // Body - process 4-byte chunks
        let nblocks = length / 4
        for i in 0..<nblocks {
            var k1 = getBlock(key, i * 4)

            k1 = k1 &* c1
            k1 = rotl32(k1, 15)
            k1 = k1 &* c2

            h1 ^= k1
            h1 = rotl32(h1, 13)
            h1 = h1 &* 5 &+ 0xe6546b64
        }

        // Tail - handle remaining bytes
        var k1: UInt32 = 0
        let tail = nblocks * 4

        switch length & 3 {
        case 3:
            k1 ^= UInt32(key[tail + 2]) << 16
            fallthrough
        case 2:
            k1 ^= UInt32(key[tail + 1]) << 8
            fallthrough
        case 1:
            k1 ^= UInt32(key[tail])
            k1 = k1 &* c1
            k1 = rotl32(k1, 15)
            k1 = k1 &* c2
            h1 ^= k1
        default:
            break
        }

        // Finalization
        h1 ^= UInt32(length)
        h1 = fmix32(h1)

        return h1
    }

    // MARK: - Private helpers

    private static func rotl32(_ x: UInt32, _ r: Int) -> UInt32 {
        (x << r) | (x >> (32 - r))
    }

    private static func fmix32(_ h: UInt32) -> UInt32 {
        var h = h
        h ^= h >> 16
        h = h &* 0x85ebca6b
        h ^= h >> 13
        h = h &* 0xc2b2ae35
        h ^= h >> 16
        return h
    }

    private static func getBlock(_ key: [UInt8], _ i: Int) -> UInt32 {
        // Little-endian read
        UInt32(key[i]) |
            (UInt32(key[i + 1]) << 8) |
            (UInt32(key[i + 2]) << 16) |
            (UInt32(key[i + 3]) << 24)
    }
}
