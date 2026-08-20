// Actuali/Actuali/Services/Sync/MerkleTree.swift

import Foundation

/// A node in the Merkle trie
/// Uses ternary branches (0, 1, 2) based on base-3 encoding of minutes
struct MerkleNode: Codable, Equatable {
    var hash: Int32  // Int32 for JSON compatibility (server sends signed integers)
    var children: [String: MerkleNode]  // Keys: "0", "1", "2"

    enum CodingKeys: String, CodingKey {
        case hash
        case children = "0"  // This will be overridden dynamically
    }

    init(hash: Int32 = 0, children: [String: MerkleNode] = [:]) {
        self.hash = hash
        self.children = children
    }

    static func empty() -> MerkleNode {
        MerkleNode(hash: 0, children: [:])
    }

    // MARK: - Custom Codable Implementation

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        // Decode hash if present (server sends signed Int32)
        self.hash = try container.decodeIfPresent(Int32.self, forKey: DynamicCodingKey(stringValue: "hash")!) ?? 0

        // Decode child nodes (0, 1, 2)
        var children: [String: MerkleNode] = [:]
        for key in ["0", "1", "2"] {
            if let childKey = DynamicCodingKey(stringValue: key),
               let child = try? container.decode(MerkleNode.self, forKey: childKey) {
                children[key] = child
            }
        }
        self.children = children
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)

        // Encode hash
        try container.encode(hash, forKey: DynamicCodingKey(stringValue: "hash")!)

        // Encode children with their numeric keys
        for (key, child) in children {
            if let codingKey = DynamicCodingKey(stringValue: key) {
                try container.encode(child, forKey: codingKey)
            }
        }
    }

    // Dynamic coding key for flexible JSON encoding
    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

/// Merkle trie for efficient sync diffing
/// Timestamps are mapped to paths using base-3 encoding of minutes since epoch
struct MerkleTree {
    private(set) var root: MerkleNode

    init(root: MerkleNode = .empty()) {
        self.root = root
    }

    // MARK: - Insert

    /// Insert a timestamp into the trie (mutating version)
    /// Mutates the tree by XORing the timestamp hash into all nodes along the path
    mutating func insert(_ timestamp: HLCTimestamp) {
        self = inserting(timestamp)
    }

    /// Insert a timestamp and return a new tree (non-mutating version)
    /// Use this in actor contexts where mutating methods can't be called after await
    func inserting(_ timestamp: HLCTimestamp) -> MerkleTree {
        folding(hash: timestamp.hash(), intoMinuteOf: timestamp.millis)
    }

    /// Build a trie from minute buckets, where each entry maps a time to the XOR
    /// of every message hash falling in that time's minute.
    ///
    /// Equivalent to `inserting(_:)` per message: every timestamp within a minute
    /// walks the identical path, and XOR is associative, so folding a minute's
    /// combined hash in one walk lands the same value in every node along it.
    /// Rebuilding a whole message log costs one walk per active minute this way
    /// instead of one per message.
    static func building(from minuteBuckets: [Int64: Int32]) -> MerkleTree {
        var tree = MerkleTree()
        for (millis, hash) in minuteBuckets {
            tree = tree.folding(hash: hash, intoMinuteOf: millis)
        }
        return tree
    }

    private func folding(hash: Int32, intoMinuteOf millis: Int64) -> MerkleTree {
        // XOR hash into root
        var newRoot = root
        newRoot.hash ^= hash
        newRoot = insertKey(node: newRoot, key: minuteKey(from: millis), hash: hash)

        return MerkleTree(root: newRoot)
    }

    private func insertKey(node: MerkleNode, key: String, hash: Int32) -> MerkleNode {
        guard let firstChar = key.first else { return node }

        let keyStr = String(firstChar)
        var newNode = node
        var child = node.children[keyStr] ?? MerkleNode.empty()

        // XOR hash into child
        child.hash ^= hash

        // Recurse for remaining key
        child = insertKey(node: child, key: String(key.dropFirst()), hash: hash)
        newNode.children[keyStr] = child

        return newNode
    }

    // MARK: - Diff

    /// Find the earliest divergence point between two tries
    /// Returns nil if trees are in sync, otherwise returns milliseconds since epoch
    func diff(with other: MerkleTree) -> Int64? {
        if root.hash == other.root.hash {
            return nil  // Trees match
        }

        var node1 = root
        var node2 = other.root
        var path = ""

        while true {
            // Get all keys from both nodes
            let keys = Set(node1.children.keys).union(node2.children.keys).sorted()
            var diffKey: String? = nil

            // Traverse down the trie through keys that aren't the same
            // We traverse down the keys in order
            for key in keys {
                let child1 = node1.children[key]
                let child2 = node2.children[key]

                // If one side is missing, we can't traverse further
                // This handles pruning - we don't know if we've pruned off a changed key
                guard let c1 = child1, let c2 = child2 else {
                    break
                }

                // Found a differing branch
                if c1.hash != c2.hash {
                    diffKey = key
                    break
                }
            }

            guard let dk = diffKey else {
                // No differing key found - return time for current path
                // This is either the bottom of the tree or a pruned key
                return keyToTimestamp(path)
            }

            path += dk
            node1 = node1.children[dk] ?? .empty()
            node2 = node2.children[dk] ?? .empty()
        }
    }

    // MARK: - Prune

    /// Prune old branches, keeping only the last n branches at each level (mutating version)
    /// Default is 2 to match Actual's behavior
    mutating func prune(keepLast n: Int = 2) {
        self = pruned(keepLast: n)
    }

    /// Prune and return a new tree (non-mutating version)
    /// Use this in actor contexts where mutating methods can't be called after await
    func pruned(keepLast n: Int = 2) -> MerkleTree {
        MerkleTree(root: pruneNode(root, keep: n))
    }

    private func pruneNode(_ node: MerkleNode, keep n: Int) -> MerkleNode {
        guard !node.children.isEmpty else { return node }

        var newNode = MerkleNode(hash: node.hash, children: [:])

        // Keep only the last n sorted keys
        let sortedKeys = node.children.keys.sorted()
        let keysToKeep = sortedKeys.suffix(n)

        for key in keysToKeep {
            if let child = node.children[key] {
                newNode.children[key] = pruneNode(child, keep: n)
            }
        }

        return newNode
    }

    // MARK: - Key Conversion

    /// Convert milliseconds to base-3 encoded minute key
    /// Matches the TypeScript: Number(Math.floor(timestamp.millis() / 1000 / 60)).toString(3)
    private func minuteKey(from millis: Int64) -> String {
        let minutes = millis / 1000 / 60
        return String(minutes, radix: 3)
    }

    /// Convert base-3 key back to milliseconds
    /// Pads key to 16 characters (full precision) before converting
    private func keyToTimestamp(_ key: String) -> Int64 {
        // 16 is the length of the base 3 value of the current time in minutes
        // Ensure it's padded to create the full value
        let padded = key + String(repeating: "0", count: max(0, 16 - key.count))

        // Parse the base 3 representation
        let minutes = Int64(padded, radix: 3) ?? 0
        return minutes * 60 * 1000
    }
}
