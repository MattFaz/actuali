import CryptoKit
import Foundation
import Testing
import GRDB
@testable import Actuali

// Fixture-based tests proving the Swift sync engine is bit-identical to the
// upstream JS implementation vendored at actual/packages/crdt/src/crdt/.
//
// Provenance of every vector is cited inline. Vectors marked "computed-by-node"
// were produced by executing the upstream source directly:
//   node --experimental-strip-types  (actual/ checkout, node_modules present)
// importing actual/packages/crdt/src/crdt/{timestamp.ts,merkle.ts} and
// actual/packages/crdt/src/proto/sync_pb.ts with real (unmocked) hashes.

// MARK: - MurmurHash3

struct MurmurHash3FixtureTests {

    // Upstream: timestamp.ts Timestamp.hash() = murmurhash.v3(this.toString())
    // with the `murmurhash` npm package (UTF-8 via TextEncoder, seed 0).
    // Values computed-by-node: require('murmurhash').v3(s).
    // The first two also appear in
    // actual/packages/crdt/src/crdt/__snapshots__/merkle.test.ts.snap
    // ("adding an item works": hashes 1983295247 / 1469038940).
    @Test func timestampStringVectors() {
        let vectors: [(String, UInt32)] = [
            ("2018-11-12T13:21:40.122Z-0000-0123456789ABCDEF", 1983295247),
            ("2018-11-13T13:21:40.122Z-0000-0123456789ABCDEF", 1469038940),
            ("1970-01-01T00:00:00.000Z-0000-0000000000000000", 4179357717),
            ("2015-04-24T22:23:42.123Z-1000-0123456789ABCDEF", 2838536857),
            ("9999-12-31T23:59:59.999Z-FFFF-FFFFFFFFFFFFFFFF", 1359285735),
            ("2019-06-03T16:40:53.876Z-0000-9f66d38cba0ef956", 779909595),
        ]
        for (input, expected) in vectors {
            #expect(MurmurHash3.hash(input) == expected, "hash mismatch for \(input)")
        }
    }

    // Tail-length coverage (0..3 trailing bytes plus a full block).
    // Computed-by-node with the murmurhash package used by upstream.
    @Test func tailLengthVectors() {
        let vectors: [(String, UInt32)] = [
            ("", 0),
            ("abc", 3017643002),
            ("abcd", 1139631978),
            ("abcde", 3902511862),
            ("abcdef", 1635893381),
        ]
        for (input, expected) in vectors {
            #expect(MurmurHash3.hash(input) == expected, "hash mismatch for \(input)")
        }
    }

    // Upstream's murmurhash package encodes input with TextEncoder (UTF-8),
    // so multi-byte characters are well-defined. Computed-by-node.
    @Test func nonASCIIVectors() {
        #expect(MurmurHash3.hash("café") == 605818632)
        #expect(MurmurHash3.hash("日本語") == 2779017879)
    }
}

// MARK: - HLCTimestamp parse/format

struct HLCTimestampFixtureTests {

    // Upstream: timestamp.test.ts "parsing > should parse" — each valid input
    // must round-trip exactly (parsed.toString() === validInput).
    @Test func parseRoundTripValidInputs() {
        let validInputs = [
            "1970-01-01T00:00:00.000Z-0000-0000000000000000",
            "2015-04-24T22:23:42.123Z-1000-0123456789ABCDEF",
            "9999-12-31T23:59:59.999Z-FFFF-FFFFFFFFFFFFFFFF",
        ]
        for input in validInputs {
            let parsed = HLCTimestamp.parse(input)
            #expect(parsed != nil, "failed to parse \(input)")
            #expect(parsed?.toString() == input, "round trip mismatch for \(input)")
        }
    }

    // Upstream: timestamp.test.ts "parsing > should parse" field bounds, plus
    // exact millis computed-by-node: Date.parse('2015-04-24T22:23:42.123Z').
    @Test func parsedFieldValues() {
        let parsed = HLCTimestamp.parse("2015-04-24T22:23:42.123Z-1000-0123456789ABCDEF")
        #expect(parsed?.millis == 1_429_914_222_123)
        #expect(parsed?.counter == 0x1000)
        #expect(parsed?.node == "0123456789ABCDEF")
    }

    // Upstream: timestamp.test.ts "parsing > should not parse" (string inputs;
    // the non-string entries don't apply to a typed Swift API).
    @Test func parseRejectsInvalidInputs() {
        let invalidInputs = [
            "",
            " ",
            "0",
            "invalid",
            "1969-1-1T0:0:0.0Z-0-0-0",
            "1969-01-01T00:00:00.000Z-0000-0000000000000000",   // negative millis
            "10000-01-01T00:00:00.000Z-FFFF-FFFFFFFFFFFFFFFF", // 5-digit year
            "9999-12-31T23:59:59.999Z-10000-FFFFFFFFFFFFFFFF", // counter > FFFF
            "9999-12-31T23:59:59.999Z-FFFF-10000000000000000", // node > 16 chars
        ]
        for input in invalidInputs {
            #expect(HLCTimestamp.parse(input) == nil, "should not parse \(input)")
        }
    }

    // Upstream: timestamp.ts Timestamp.zero / Timestamp.max literals.
    @Test func zeroAndMaxFormat() {
        #expect(HLCTimestamp.zero.toString() == "1970-01-01T00:00:00.000Z-0000-0000000000000000")
        #expect(HLCTimestamp.max.toString() == "9999-12-31T23:59:59.999Z-FFFF-FFFFFFFFFFFFFFFF")
    }

    // Upstream: timestamp.ts toString() pads counter to 4 uppercase hex digits
    // and node to 16 chars. Computed-by-node:
    // new Timestamp(1542028900122, 4096, 'ABC').toString().
    @Test func counterAndNodePadding() {
        let ts = HLCTimestamp(millis: 1_542_028_900_122, counter: 0x1000, node: "ABC")
        #expect(ts.toString() == "2018-11-12T13:21:40.122Z-1000-0000000000000ABC")

        let minCounter = HLCTimestamp(millis: 0, counter: 0, node: "0123456789abcdef")
        #expect(minCounter.toString() == "1970-01-01T00:00:00.000Z-0000-0123456789abcdef")

        let maxCounter = HLCTimestamp(millis: 0, counter: 0xFFFF, node: "0123456789abcdef")
        #expect(maxCounter.toString() == "1970-01-01T00:00:00.000Z-FFFF-0123456789abcdef")
    }

    // Upstream: timestamp.ts Timestamp.since.
    @Test func sinceFormat() {
        #expect(HLCTimestamp.since("2017-01-01T00:00:00.000Z")
                == "2017-01-01T00:00:00.000Z-0000-0000000000000000")
    }

    // Upstream Timestamp.hash() returns murmurhash.v3 unsigned; the Swift port
    // reinterprets the same bits as Int32 because JS XOR (used by the merkle
    // trie) operates on signed 32-bit values. Same bits, signed view.
    // Unsigned values computed-by-node: Timestamp.parse(s).hash().
    @Test func timestampHashMatchesUpstream() {
        let vectors: [(String, UInt32)] = [
            ("2018-11-12T13:21:40.122Z-0000-0123456789ABCDEF", 1983295247),
            ("2019-06-03T16:40:53.876Z-0000-9f66d38cba0ef956", 779909595),
            ("1970-01-01T00:00:00.000Z-0000-0000000000000000", 4179357717),
            ("9999-12-31T23:59:59.999Z-FFFF-FFFFFFFFFFFFFFFF", 1359285735),
        ]
        for (input, unsignedHash) in vectors {
            let ts = HLCTimestamp.parse(input)
            #expect(ts != nil)
            #expect(ts?.hash() == Int32(bitPattern: unsignedHash), "hash mismatch for \(input)")
        }
    }

    // Upstream: timestamp.test.ts "comparison > should be in order".
    @Test func ordering() {
        let mid = HLCTimestamp.parse("2015-04-24T22:23:42.123Z-1000-0123456789ABCDEF")!
        #expect(HLCTimestamp.zero < mid)
        #expect(mid < HLCTimestamp.max)
        #expect(HLCTimestamp.zero < HLCTimestamp.max)
    }
}

// MARK: - MerkleTree

struct MerkleTreeFixtureTests {

    private func ts(_ string: String) -> HLCTimestamp {
        HLCTimestamp.parse(string)!
    }

    /// Serializes a MerkleNode exactly like JS JSON.stringify(trie): integer-like
    /// keys ("0","1","2") in ascending order first, then "hash" (JS object key
    /// ordering puts array-index keys first, ascending).
    private func canonicalJSON(_ node: MerkleNode) -> String {
        var parts: [String] = []
        for key in node.children.keys.sorted() {
            parts.append("\"\(key)\":\(canonicalJSON(node.children[key]!))")
        }
        parts.append("\"hash\":\(node.hash)")
        return "{" + parts.joined(separator: ",") + "}"
    }

    // Upstream: merkle.test.ts "adding an item works" — full trie structure
    // from __snapshots__/merkle.test.ts.snap (real, unmocked hashes). The JSON
    // string below is JSON.stringify of that exact snapshot, computed-by-node.
    @Test func insertProducesUpstreamSnapshotStructure() {
        var tree = MerkleTree()
        tree.insert(ts("2018-11-12T13:21:40.122Z-0000-0123456789ABCDEF"))
        tree.insert(ts("2018-11-13T13:21:40.122Z-0000-0123456789ABCDEF"))

        let expected = """
            {"1":{"2":{"1":{"0":{"1":{"0":{"0":{"2":{"0":{"1":{"1":{"0":{"2":{"2":{"0":{"0":{"hash":1983295247},"hash":1983295247},"hash":1983295247},"hash":1983295247},"hash":1983295247},"hash":1983295247},"hash":1983295247},"hash":1983295247},"1":{"0":{"1":{"0":{"2":{"0":{"0":{"0":{"hash":1469038940},"hash":1469038940},"hash":1469038940},"hash":1469038940},"hash":1469038940},"hash":1469038940},"hash":1469038940},"hash":1469038940},"hash":565800531},"hash":565800531},"hash":565800531},"hash":565800531},"hash":565800531},"hash":565800531},"hash":565800531},"hash":565800531},"hash":565800531}
            """
        #expect(canonicalJSON(tree.root) == expected)
        #expect(tree.root.hash == 565800531)
    }

    // Upstream: merkle.test.ts "diff returns the correct time difference",
    // re-run with real Timestamp.hash() instead of the test's mocked hashes
    // (the Swift API has no hash injection point). Root hashes and diff
    // results computed-by-node from upstream merkle.ts/timestamp.ts.
    @Test func diffReturnsCorrectTimeDifference() {
        let messages = [
            ts("2018-11-13T13:20:40.122Z-0000-0123456789ABCDEF"),
            ts("2018-11-14T13:05:35.122Z-0000-0123456789ABCDEF"),
            ts("2018-11-15T22:19:00.122Z-0000-0123456789ABCDEF"),
            ts("2018-11-20T13:19:40.122Z-0000-0123456789ABCDEF"),
            ts("2018-11-25T13:19:40.122Z-0000-0123456789ABCDEF"),
        ]

        var trie1 = MerkleTree()
        trie1.insert(messages[0])
        trie1.insert(messages[1])
        trie1.insert(messages[2])
        #expect(trie1.root.hash == 1562158574)

        var trie2 = MerkleTree()
        trie2.insert(messages[3])
        trie2.insert(messages[4])
        #expect(trie2.root.hash == -1230958401)

        // Upstream expects 2018-11-02T17:15:00.000Z (millis computed-by-node)
        #expect(trie1.diff(with: trie2) == 1_541_178_900_000)

        trie1.insert(messages[3])
        trie1.insert(messages[4])
        trie2.insert(messages[0])
        trie2.insert(messages[1])
        trie2.insert(messages[2])
        #expect(trie1.root.hash == -339888815)
        #expect(trie1.root.hash == trie2.root.hash)
        #expect(trie1.diff(with: trie2) == nil)
    }

    // Upstream: merkle.test.ts "diffing works with empty tries".
    @Test func diffWithEmptyTrie() {
        let empty = MerkleTree()
        var populated = MerkleTree()
        populated.insert(ts("2009-01-02T10:17:37.789Z-0000-0000testinguuid1"))

        #expect(empty.diff(with: populated) == 0)
        #expect(populated.diff(with: empty) == 0)
        #expect(empty.root.hash == 0)
        #expect(empty.diff(with: MerkleTree()) == nil)
    }

    private var pruneScenarioMessages: [HLCTimestamp] {
        [
            ts("2018-11-01T01:00:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T01:09:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T01:18:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T01:27:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T01:36:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T01:45:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T01:54:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T02:03:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T02:10:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T02:19:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T02:28:00.000Z-0000-0123456789ABCDEF"),
            ts("2018-11-01T02:37:00.000Z-0000-0123456789ABCDEF"),
        ]
    }

    // Upstream: merkle.test.ts "pruning works and keeps correct hashes",
    // re-run with real hashes (root hash and full pruned structure
    // computed-by-node from upstream merkle.ts).
    @Test func pruningKeepsCorrectHashes() {
        var tree = MerkleTree()
        for message in pruneScenarioMessages {
            tree.insert(message)
        }
        #expect(tree.root.hash == 345045312)

        let pruned = tree.pruned()
        #expect(pruned.root.hash == 345045312)

        let expected = """
            {"1":{"2":{"1":{"0":{"0":{"2":{"2":{"2":{"1":{"2":{"2":{"0":{"1":{"1":{"2":{"0":{"hash":-1718969198},"hash":-1718969198},"hash":-1718969198},"2":{"2":{"0":{"hash":384820918},"hash":384820918},"hash":384820918},"hash":1710637055},"2":{"1":{"2":{"0":{"hash":-497345306},"hash":-497345306},"hash":-497345306},"2":{"2":{"0":{"hash":1003725159},"hash":1003725159},"hash":1003725159},"hash":613353200},"hash":1710746760},"1":{"0":{"1":{"1":{"1":{"hash":-666153754},"hash":-666153754},"hash":-666153754},"2":{"1":{"1":{"hash":748821548},"hash":748821548},"hash":748821548},"hash":703357274},"1":{"0":{"1":{"1":{"hash":1485534354},"hash":1485534354},"hash":1485534354},"hash":1485534354},"hash":1902581192},"hash":345045312},"hash":345045312},"hash":345045312},"hash":345045312},"hash":345045312},"hash":345045312},"hash":345045312},"hash":345045312},"hash":345045312},"hash":345045312},"hash":345045312},"hash":345045312}
            """
        #expect(canonicalJSON(pruned.root) == expected)
    }

    // Upstream: merkle.test.ts "diffing differently shaped tries returns
    // correct time", re-run with real hashes; all diff millis computed-by-node
    // (results match the upstream test's expected ISO strings exactly).
    @Test func diffingDifferentlyShapedTries() {
        var tree = MerkleTree()
        for message in pruneScenarioMessages {
            tree.insert(message)
        }

        // Case 0: comparing with an empty trie returns the base time
        #expect(MerkleTree().diff(with: tree) == 0)  // 1970-01-01T00:00:00.000Z
        #expect(tree.diff(with: MerkleTree()) == 0)

        // Case 1: older message modifying the 1st of 3 branches
        let trie1 = tree.inserting(ts("2018-11-01T00:59:00.000Z-0000-0123456789ABCDEF"))

        #expect(trie1.diff(with: tree) == 1_541_033_640_000)                    // 2018-11-01T00:54:00.000Z
        #expect(trie1.pruned().diff(with: tree) == 1_541_033_100_000)           // 2018-11-01T00:45:00.000Z
        #expect(trie1.diff(with: tree.pruned()) == 1_541_033_100_000)           // 2018-11-01T00:45:00.000Z
        #expect(trie1.pruned().diff(with: tree.pruned()) == 1_541_033_100_000)  // 2018-11-01T00:45:00.000Z

        // Case 2: second message modifies the 2nd key at the same level
        let trie2 = tree
            .inserting(ts("2018-11-01T00:59:00.000Z-0000-0123456789ABCDEF"))
            .inserting(ts("2018-11-01T01:15:00.000Z-0000-0123456789ABCDEF"))

        #expect(trie2.diff(with: tree) == 1_541_033_640_000)                    // 2018-11-01T00:54:00.000Z
        #expect(trie2.pruned().diff(with: tree) == 1_541_033_100_000)           // 2018-11-01T00:45:00.000Z
        #expect(trie2.diff(with: tree.pruned()) == 1_541_033_100_000)           // 2018-11-01T00:45:00.000Z
        #expect(trie2.pruned().diff(with: tree.pruned()) == 1_541_034_720_000)  // 2018-11-01T01:12:00.000Z
    }

    // Upstream: merkle.ts insert() derives the trie path from
    // Math.floor(millis / 1000 / 60).toString(3). The snapshot structure
    // already pins this; here the leading path is asserted explicitly.
    // Base-3 key for 2018-11-12T13:21:40.122Z computed-by-node:
    // "1210100201102200" (minutes 25700481).
    @Test func base3MinuteKeyDerivation() {
        var tree = MerkleTree()
        tree.insert(ts("2018-11-12T13:21:40.122Z-0000-0123456789ABCDEF"))

        var node = tree.root
        for key in "1210100201102200" {
            let child = node.children[String(key)]
            #expect(child != nil, "missing trie child for key \(key)")
            #expect(node.children.count == 1)
            node = child ?? .empty()
        }
        #expect(node.children.isEmpty)
        #expect(node.hash == 1983295247)
    }

    // deriveMerkleFromMessageLog reads the trie's minute straight off the
    // ISO-8601 prefix instead of parsing a Date, so it must agree with `parse`
    // exactly — including across leap days, century boundaries and month ends,
    // where hand-rolled calendar math goes wrong.
    @Test(arguments: [
        "1970-01-01T00:00:00.000Z-0000-0123456789ABCDEF",
        "1970-01-01T00:00:59.999Z-FFFF-0123456789ABCDEF",
        "1999-12-31T23:59:00.000Z-0000-0123456789ABCDEF",
        "2000-02-29T12:34:56.789Z-0000-0123456789ABCDEF",  // leap day, century leap year
        "2018-11-01T00:45:00.000Z-0000-0123456789ABCDEF",
        "2024-02-29T23:59:59.999Z-0000-0123456789ABCDEF",
        "2026-03-01T00:00:00.000Z-0000-0123456789ABCDEF",  // day after a non-leap February
        "2026-07-22T10:00:00.000Z-0000-a1b2c3d4e5f60718",
        "2026-12-31T23:59:59.999Z-0000-0123456789ABCDEF",
        "2100-03-01T00:00:00.000Z-0000-0123456789ABCDEF",  // century non-leap year
    ])
    func minuteArithmeticMatchesDateParsing(_ string: String) throws {
        let parsed = try #require(HLCTimestamp.parse(string))
        #expect(HLCTimestamp.minutesSinceEpoch(of: string) == parsed.millis / 1000 / 60)
    }

    @Test func minuteArithmeticRejectsMalformedTimestamps() {
        #expect(HLCTimestamp.minutesSinceEpoch(of: "") == nil)
        #expect(HLCTimestamp.minutesSinceEpoch(of: "2026-07-22") == nil)
        #expect(HLCTimestamp.minutesSinceEpoch(of: "not-a-timestamp-at-all") == nil)
        #expect(HLCTimestamp.minutesSinceEpoch(of: "2026-13-22T10:00:00.000Z-0000-0") == nil)
        #expect(HLCTimestamp.minutesSinceEpoch(of: "2026-07-22T99:00:00.000Z-0000-0") == nil)
    }

    // `building(from:)` folds one XOR per active minute instead of one insert
    // per message, so a whole message log can be re-derived cheaply
    // (BudgetDatabase.deriveMerkleFromMessageLog). It must produce the identical
    // trie — including for several messages sharing a minute, where the folding
    // relies on XOR being associative along one shared path.
    @Test func bulkBuildMatchesPerMessageInsertion() {
        let timestamps = [
            "2018-11-01T00:47:12.000Z-0000-0123456789ABCDEF",
            "2018-11-01T00:47:39.000Z-0001-0123456789ABCDEF",  // same minute
            "2018-11-01T00:47:39.500Z-0000-FEDCBA9876543210",  // same minute
            "2018-11-01T01:15:00.000Z-0000-0123456789ABCDEF",
            "2018-11-12T13:21:40.122Z-0000-0123456789ABCDEF",
        ].map(ts)

        var incremental = MerkleTree()
        var buckets: [Int64: Int32] = [:]
        for timestamp in timestamps {
            incremental = incremental.inserting(timestamp)
            // One bucket per minute, keyed by any millis inside it.
            let minute = timestamp.millis / 60_000 * 60_000
            buckets[minute, default: 0] ^= timestamp.hash()
        }

        let bulk = MerkleTree.building(from: buckets)
        #expect(bulk.root == incremental.root)
        #expect(bulk.diff(with: incremental) == nil)
    }
}

// MARK: - SyncEncoder / protobuf

struct SyncEncoderFixtureTests {

    // Known-bytes vectors computed-by-node with upstream's generated protobuf
    // schema (actual/packages/crdt/src/proto/sync_pb.ts via @bufbuild/protobuf
    // toBinary), the encoder used by loot-core's sync (server/sync/encoder.ts).
    @Test func messageEncodesToUpstreamBytes() throws {
        var inner = Message()
        inner.dataset = "accounts"
        inner.row = "r1"
        inner.column = "name"
        inner.value = "S:Checking"

        let expectedHex = "0a086163636f756e7473120272311a046e616d65220a533a436865636b696e67"
        #expect(try inner.serializedData().map { String(format: "%02x", $0) }.joined() == expectedHex)
    }

    @Test func syncRequestEncodesToUpstreamBytes() throws {
        let message = CRDTMessage(
            timestamp: HLCTimestamp.parse("2019-06-03T16:40:53.876Z-0000-9f66d38cba0ef956")!,
            dataset: "accounts",
            row: "r1",
            column: "name",
            value: "S:Checking"
        )
        let encoder = SyncEncoder(encryptionKey: nil)
        let data = try encoder.encode(
            messages: [message],
            fileId: "file-1",
            groupId: "group-1",
            keyId: nil,
            since: "2017-01-01T00:00:00.000Z-0000-0000000000000000"
        )

        // toBinary(SyncRequestSchema, {messages:[env], fileId:'file-1',
        // groupId:'group-1', keyId:'', since:'2017-...'}) computed-by-node
        let expectedHex = "0a520a2e323031392d30362d30335431363a34303a35332e3837365a2d303030302d39663636"
            + "6433386362613065663935361a200a086163636f756e7473120272311a046e616d65220a533a436865636b"
            + "696e67120666696c652d311a0767726f75702d31322e323031372d30312d30315430303a30303a30302e3030"
            + "305a2d303030302d30303030303030303030303030303030"
        #expect(data.map { String(format: "%02x", $0) }.joined() == expectedHex)
    }

    @Test func plaintextRoundTrip() throws {
        let timestamp = HLCTimestamp.parse("2019-06-03T16:40:53.876Z-0000-9f66d38cba0ef956")!
        let original = CRDTMessage(
            timestamp: timestamp,
            dataset: "transactions",
            row: "8f6a9a52-906b-4e3c-bd09-621bd11b3c33",
            column: "amount",
            value: "N:-1050"
        )

        var inner = Message()
        inner.dataset = original.dataset
        inner.row = original.row
        inner.column = original.column
        inner.value = original.value

        var envelope = MessageEnvelope()
        envelope.timestamp = original.timestamp.toString()
        envelope.isEncrypted = false
        envelope.content = try inner.serializedData()

        var response = SyncResponse()
        response.messages = [envelope]
        response.merkle = #"{"hash":565800531,"1":{"hash":565800531}}"#

        let encoder = SyncEncoder(encryptionKey: nil)
        let (messages, merkle) = try encoder.decode(response.serializedData())

        #expect(messages.count == 1)
        #expect(messages.first?.timestamp == timestamp)
        #expect(messages.first?.dataset == original.dataset)
        #expect(messages.first?.row == original.row)
        #expect(messages.first?.column == original.column)
        #expect(messages.first?.value == original.value)
        #expect(merkle.hash == 565800531)
        #expect(merkle.children["1"]?.hash == 565800531)
    }

    @Test func encryptedRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let timestamp = HLCTimestamp.parse("2019-06-03T16:40:53.876Z-0000-9f66d38cba0ef956")!
        let original = CRDTMessage(
            timestamp: timestamp,
            dataset: "accounts",
            row: "acct-1",
            column: "name",
            value: "S:Chécking ✓"
        )

        let encoder = SyncEncoder(encryptionKey: key)
        let requestData = try encoder.encode(
            messages: [original],
            fileId: "file-1",
            groupId: "group-1",
            keyId: "key-1",
            since: HLCTimestamp.since("1970-01-01T00:00:00.000Z")
        )

        let request = try SyncRequest(serializedData: requestData)
        #expect(request.messages.count == 1)
        #expect(request.messages[0].isEncrypted)

        // Echo the encrypted envelope back through the decode path
        var response = SyncResponse()
        response.messages = request.messages
        response.merkle = #"{"hash":0}"#

        let (messages, _) = try encoder.decode(response.serializedData())
        #expect(messages.count == 1)
        #expect(messages.first?.timestamp == timestamp)
        #expect(messages.first?.dataset == original.dataset)
        #expect(messages.first?.row == original.row)
        #expect(messages.first?.column == original.column)
        #expect(messages.first?.value == original.value)
    }
}

// MARK: - End-to-end convergence

struct SyncConvergenceFixtureTests {

    /// accounts and messages_crdt normally come from the downloaded budget
    /// file, so create them with the upstream schema (matches
    /// BudgetDatabaseApplyMessagesTests).
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                )
                """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func accounts(path: URL) throws -> [(id: String, name: String?)] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name FROM accounts ORDER BY id")
                .map { ($0["id"] as String, $0["name"] as String?) }
        }
    }

    /// Mirrors SyncClient.receiveMessages: per-field LWW filter via
    /// filterNewMessages, apply the winners, then dedup-insert into
    /// messages_crdt and fold only newly inserted timestamps into the merkle
    /// trie. Intentionally omits the `clock.receive` step and the post-insert
    /// `merkle.pruned()` step from receiveMessages — if those acquire
    /// state-affecting behavior this helper must be revisited.
    private func apply(
        _ batch: [CRDTMessage],
        to database: BudgetDatabase,
        merkle: inout MerkleTree
    ) throws {
        let newMessages = try database.filterNewMessages(batch)
        try database.applyMessages(newMessages)
        let inserted = try database.insertMessages(batch)
        for message in inserted {
            merkle = merkle.inserting(message.timestamp)
        }
    }

    // Two in-memory clients exchange messages (including overlap/echo and
    // reversed ordering) through the real insert/apply path and must converge
    // to identical merkle hashes and identical table state — the invariant the
    // upstream CRDT design guarantees (actual/packages/crdt).
    @Test func twoClientsConvergeToIdenticalState() throws {
        func message(
            _ isoTimestamp: String, node: String,
            row: String, column: String, value: String
        ) -> CRDTMessage {
            CRDTMessage(
                timestamp: HLCTimestamp.parse("\(isoTimestamp)-0000-\(node)")!,
                dataset: "accounts",
                row: row,
                column: column,
                value: value
            )
        }

        let clientAMessages = [
            message("2024-01-15T10:00:00.000Z", node: "aaaaaaaaaaaaaaaa",
                    row: "acct-1", column: "name", value: "S:Checking"),
            message("2024-01-15T10:00:01.000Z", node: "aaaaaaaaaaaaaaaa",
                    row: "acct-1", column: "offbudget", value: "N:0"),
            message("2024-01-16T09:30:00.000Z", node: "aaaaaaaaaaaaaaaa",
                    row: "acct-2", column: "name", value: "S:Savings"),
        ]
        let clientBMessages = [
            // Same field as A's first message but later: B's value must win on
            // both clients regardless of arrival order
            message("2024-01-17T12:00:00.000Z", node: "bbbbbbbbbbbbbbbb",
                    row: "acct-1", column: "name", value: "S:Everyday Checking"),
            message("2024-01-17T12:00:01.000Z", node: "bbbbbbbbbbbbbbbb",
                    row: "acct-3", column: "name", value: "S:Brokerage"),
        ]

        let (clientA, pathA) = try makeDatabase()
        defer { cleanup(pathA) }
        let (clientB, pathB) = try makeDatabase()
        defer { cleanup(pathB) }
        var merkleA = MerkleTree()
        var merkleB = MerkleTree()

        // Each client applies its own messages
        try apply(clientAMessages, to: clientA, merkle: &merkleA)
        try apply(clientBMessages, to: clientB, merkle: &merkleB)
        #expect(merkleA.diff(with: merkleB) != nil)

        // Exchange: B receives A's batch in reverse order; A receives B's
        // batch along with an echo of one of its own messages (server echo)
        try apply(clientBMessages + [clientAMessages[0]], to: clientA, merkle: &merkleA)
        try apply(clientAMessages.reversed(), to: clientB, merkle: &merkleB)

        #expect(merkleA.root.hash != 0)
        #expect(merkleA.root.hash == merkleB.root.hash)
        #expect(merkleA.diff(with: merkleB) == nil)

        let accountsA = try accounts(path: pathA)
        let accountsB = try accounts(path: pathB)
        #expect(accountsA.count == 3)
        #expect(accountsA.map(\.id) == accountsB.map(\.id))
        #expect(accountsA.map(\.name) == accountsB.map(\.name))
        #expect(accountsA.first(where: { $0.id == "acct-1" })?.name == "Everyday Checking")
    }
}
