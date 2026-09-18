import Foundation

struct Payee: Identifiable, Hashable {
    let id: String
    var name: String
    var transferAccountId: String? // If this payee represents a transfer to another account
    var tombstone: Bool = false
}

// MARK: - CRDTSyncable

extension Payee: CRDTSyncable {
    static var datasetName: String {
        "payees"
    }

    var syncableFields: [String: Any?] {
        [
            "name": name,
            "transfer_acct": transferAccountId,
            "tombstone": tombstone ? 1 : 0
        ]
    }
}

// MARK: - Payee Mapping

struct PayeeMapping: Identifiable, Hashable {
    let id: String
    let targetId: String
}

extension PayeeMapping: CRDTSyncable {
    static var datasetName: String {
        "payee_mapping"
    }

    var syncableFields: [String: Any?] {
        [
            "targetId": targetId
        ]
    }
}
