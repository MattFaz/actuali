import Foundation

/// The kind of entry being captured by the add/edit transaction form.
enum TransactionType: Hashable {
    case expense
    case income
    case transfer
}

struct Transaction: Identifiable, Hashable {
    let id: String
    var accountId: String
    var date: Int // YYYYMMDD format
    var amount: Int // Stored in cents (negative = outflow, positive = inflow)
    var payeeId: String?
    var payeeName: String? // Denormalized for display
    var categoryId: String?
    var categoryName: String? // Denormalized for display
    var notes: String?
    var cleared: Bool
    var reconciled: Bool
    var transferId: String? // Links to paired transfer transaction
    var isParent: Bool // True if this is a split parent
    var parentId: String? // Links to parent if this is a split child
    var tombstone: Bool
    var sortOrder: Double? // Timestamp in ms, determines order within same date
    var importedPayee: String? // Original payee text from import / Shortcut entry
    // Payee's transfer_acct: the account on the other side when the payee is a
    // transfer payee, nil otherwise. Only populated by the reports fetch, where
    // engines need it to exclude transfers the way the WebUI does. Not synced
    // (it lives on the payee, not the transaction).
    var transferAcct: String? = nil
    // One entry per live child of a split parent, in entry order. Only
    // populated by fetchTransactions for isParent rows, so the list row can
    // show the breakdown ("Food $6.00, Fun $4.00"). Display-only, not synced.
    var splitPortions: [SplitPortion]? = nil

    struct SplitPortion: Hashable {
        var categoryName: String?
        var amount: Int  // cents, signed like the parent
    }

    var dateFormatted: String {
        let year = date / 10000
        let month = (date % 10000) / 100
        let day = date % 100

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        guard let date = Calendar.current.date(from: components) else {
            return "\(year)-\(month)-\(day)"
        }

        return date.formatted(date: .abbreviated, time: .omitted)
    }

    var isOutflow: Bool {
        amount < 0
    }

    /// Convert a dollar amount to integer cents, rounding half away from zero
    /// (e.g. 8.20 → 820, not 819 via truncation).
    /// - Returns: `nil` if the value is non-finite or outside the exactly
    ///   representable integer range of `Double` (±2^53).
    static func cents(fromDollars dollars: Double) -> Int? {
        let cents = (dollars * 100).rounded()
        guard cents.isFinite, abs(cents) <= 9_007_199_254_740_992 else { return nil }
        return Int(cents)
    }

    /// Encode a calendar date as the YYYYMMDD integer used throughout the
    /// database (e.g. 20251209).
    static func yyyymmdd(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    /// Inverse of `yyyymmdd(from:)`. Falls back to today for values that
    /// don't decode to a real calendar date.
    static func date(fromYYYYMMDD value: Int) -> Date {
        var components = DateComponents()
        components.year = value / 10000
        components.month = (value % 10000) / 100
        components.day = value % 100
        return Calendar.current.date(from: components) ?? Date()
    }
}

// MARK: - CRDTSyncable

extension Transaction: CRDTSyncable {
    static var datasetName: String { "transactions" }

    var syncableFields: [String: Any?] {
        [
            "acct": accountId,
            "date": date,
            "description": payeeId,      // payeeId maps to "description" column
            "category": categoryId,
            "amount": amount,
            "notes": notes,
            "cleared": cleared ? 1 : 0,
            "reconciled": reconciled ? 1 : 0,
            "transferred_id": transferId,
            "isParent": isParent ? 1 : 0,
            "isChild": parentId != nil ? 1 : 0,
            "parent_id": parentId,
            "tombstone": tombstone ? 1 : 0,
            "sort_order": sortOrder ?? Date().timeIntervalSince1970 * 1000,
            "imported_description": importedPayee
        ]
    }
}
