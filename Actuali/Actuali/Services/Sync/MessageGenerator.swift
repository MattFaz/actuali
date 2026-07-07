// Actuali/Actuali/Services/Sync/MessageGenerator.swift

import Foundation

/// Generates CRDT messages for model changes
actor MessageGenerator {
    private let clock: HybridLogicalClock

    init(clock: HybridLogicalClock) {
        self.clock = clock
    }

    /// Generate messages for inserting a new object
    func messagesForInsert<T: CRDTSyncable>(_ object: T) async throws -> [CRDTMessage] {
        let dataset = T.datasetName
        let row = object.id

        var messages: [CRDTMessage] = []

        for (column, value) in object.syncableFields {
            let timestamp = try await clock.send()
            messages.append(CRDTMessage(
                timestamp: timestamp,
                dataset: dataset,
                row: row,
                column: column,
                value: CRDTValue.serialize(value)
            ))
        }

        return messages
    }

    /// Generate messages for updating specific fields
    func messagesForUpdate<T: CRDTSyncable>(
        _ object: T,
        changedFields: Set<String>
    ) async throws -> [CRDTMessage] {
        let dataset = T.datasetName
        let row = object.id
        let allFields = object.syncableFields

        var messages: [CRDTMessage] = []

        for column in changedFields {
            guard let value = allFields[column] else { continue }
            let timestamp = try await clock.send()
            messages.append(CRDTMessage(
                timestamp: timestamp,
                dataset: dataset,
                row: row,
                column: column,
                value: CRDTValue.serialize(value)
            ))
        }

        return messages
    }

    /// Generate messages for raw (dataset, row, column) writes — for tables
    /// like zero_budgets/reflect_budgets whose dataset is chosen at runtime
    /// and so can't be a CRDTSyncable's static datasetName.
    func messages(
        dataset: String,
        row: String,
        fields: [(column: String, value: Any?)]
    ) async throws -> [CRDTMessage] {
        var messages: [CRDTMessage] = []

        for (column, value) in fields {
            let timestamp = try await clock.send()
            messages.append(CRDTMessage(
                timestamp: timestamp,
                dataset: dataset,
                row: row,
                column: column,
                value: CRDTValue.serialize(value)
            ))
        }

        return messages
    }

    /// Generate a tombstone message (soft delete)
    func messageForDelete<T: CRDTSyncable>(_ object: T) async throws -> CRDTMessage {
        let timestamp = try await clock.send()
        return CRDTMessage(
            timestamp: timestamp,
            dataset: T.datasetName,
            row: object.id,
            column: "tombstone",
            value: CRDTValue.serialize(1)
        )
    }
}
