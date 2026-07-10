// Actuali/Actuali/Services/Sync/CRDTMessage.swift

import Foundation
import GRDB

/// A CRDT message representing a single field change
struct CRDTMessage {
    let timestamp: HLCTimestamp
    let dataset: String      // Table name: "transactions", "accounts", etc.
    let row: String          // Row ID (UUID)
    let column: String       // Field name: "amount", "date", etc.
    let value: String        // Serialized value: "N:1234", "S:text", "0:"
}

/// Value serialization matching Actual's format
enum CRDTValue {

    /// Serialize a value for CRDT storage
    static func serialize(_ value: Any?) -> String {
        switch value {
        case nil:
            return "0:"
        case let n as Int:
            return "N:\(n)"
        case let n as Int64:
            return "N:\(n)"
        case let d as Double:
            // Full precision — upstream parses "N:" payloads with parseFloat,
            // so fractional values (e.g. coordinates) must not be truncated.
            return "N:\(d)"
        case let s as String:
            return "S:\(s)"
        case let b as Bool:
            return "N:\(b ? 1 : 0)"
        default:
            return "0:"
        }
    }

    /// Deserialize a value from CRDT storage to a GRDB-compatible DatabaseValue
    static func deserialize(_ value: String) -> DatabaseValue {
        guard value.count >= 2 else { return .null }

        let type = value.first!
        let content = String(value.dropFirst(2))

        switch type {
        case "0":
            return .null
        case "N":
            if let intVal = Int64(content) {
                return intVal.databaseValue
            }
            if let doubleVal = Double(content) {
                return doubleVal.databaseValue
            }
            return .null
        case "S":
            return content.databaseValue
        default:
            return .null
        }
    }
}

/// Protocol for models that can be synced via CRDT
protocol CRDTSyncable {
    /// The database table name
    static var datasetName: String { get }

    /// The row ID
    var id: String { get }

    /// Dictionary of field name -> value for all syncable fields
    var syncableFields: [String: Any?] { get }
}
