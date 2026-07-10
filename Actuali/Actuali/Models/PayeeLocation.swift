import Foundation

/// A recorded GPS coordinate for a payee (upstream `payee_locations` table,
/// Actual >= 26.4.0). `createdAt` is milliseconds since epoch, matching
/// upstream's `Date.now()`.
struct PayeeLocation: Identifiable, Hashable {
    let id: String
    let payeeId: String
    let latitude: Double
    let longitude: Double
    let createdAt: Int64
    var tombstone: Bool = false
}

extension PayeeLocation: CRDTSyncable {
    static var datasetName: String { "payee_locations" }

    var syncableFields: [String: Any?] {
        [
            "payee_id": payeeId,
            "latitude": latitude,
            "longitude": longitude,
            "created_at": createdAt,
            "tombstone": tombstone ? 1 : 0
        ]
    }
}

/// A payee paired with its closest recorded location relative to the query
/// point (upstream `NearbyPayeeEntity`).
struct NearbyPayee: Identifiable, Hashable {
    let payee: Payee
    let location: PayeeLocation
    let distanceMeters: Double

    var id: String { payee.id }
}
