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
    var schedule: String? = nil // Id of the schedule that posted this transaction, nil if entered manually
    // Bank-import dedup key (Actual's imported_id, stored as financial_id).
    // Set at creation time by the Wallet import; not read back by the fetch
    // paths, so it is nil on fetched rows — dedup queries the column directly.
    var financialId: String? = nil
    // Marks the special "opening balance" transaction created alongside a
    // new account (Actual's starting_balance_flag). Only ever set at
    // creation, matching financialId's write-only shape below.
    var startingBalanceFlag: Bool = false
    // Payee's transfer_acct: the account on the other side when the payee is a
    // transfer payee, nil otherwise. Populated by the display and reports
    // fetches so rows can render transfers as transfers and engines can
    // exclude them the way the WebUI does. Not synced (it lives on the payee,
    // not the transaction).
    var transferAcct: String? = nil
    // One entry per live child of a split parent, in entry order. Only
    // populated by fetchTransactions for isParent rows, so the list row can
    // show the breakdown ("Food $6.00, Fun $4.00"). Display-only, not synced.
    var splitPortions: [SplitPortion]? = nil

    struct SplitPortion: Hashable {
        var categoryName: String?
        var amount: Int  // cents, signed like the parent
    }

    static func formattedDate(from dateInt: Int, style: Date.FormatStyle.DateStyle = .abbreviated) -> String {
        let year = dateInt / 10000
        let month = (dateInt % 10000) / 100
        let day = dateInt % 100

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        guard let date = Calendar.current.date(from: components) else {
            return "\(year)-\(month)-\(day)"
        }

        return date.formatted(date: style, time: .omitted)
    }

    var dateFormatted: String {
        Self.formattedDate(from: date, style: .abbreviated)
    }

    var isOutflow: Bool {
        amount < 0
    }

    /// Whether this transaction still needs a category, mirroring the WebUI's
    /// "uncategorized" filter (see `BudgetDatabase.uncategorizedWhere`): split
    /// parents carry no category of their own (the children do), off-budget
    /// accounts aren't categorized at all, and transfers only take a category
    /// when the other side is off-budget — money leaving the budget still
    /// needs one (GH #123, #104).
    func needsCategory(offBudgetAccountIds: Set<String>) -> Bool {
        guard categoryId == nil, !isParent else { return false }
        guard !offBudgetAccountIds.contains(accountId) else { return false }
        if let transferAcct { return offBudgetAccountIds.contains(transferAcct) }
        return transferId == nil
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
        var fields: [String: Any?] = [
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
            "imported_description": importedPayee,
            "schedule": schedule
        ]
        // Only present on imported transactions — keeps inserts for ordinary
        // transactions identical (messagesForInsert emits every listed field,
        // nil included).
        if let financialId {
            fields["financial_id"] = financialId
        }
        if startingBalanceFlag {
            fields["starting_balance_flag"] = 1
        }
        return fields
    }
}

// MARK: - Date Grouping

struct TransactionDateGroup: Identifiable {
    let date: Int
    var id: Int { date }
    var transactions: [Transaction]

    /// Section header for the group. Spelled out in full because the rows
    /// underneath drop their own date once they're grouped.
    var title: String { Transaction.formattedDate(from: date, style: .long) }
}

extension Array where Element == Transaction {
    /// Groups transactions by date, preserving the array's existing encounter
    /// order. Every list that calls this fetches `ORDER BY date DESC`, so the
    /// groups come out newest-first and each date appears exactly once.
    func groupedByDate() -> [TransactionDateGroup] {
        var groupDict: [Int: [Transaction]] = [:]
        var order: [Int] = []
        for tx in self {
            if groupDict[tx.date] == nil {
                order.append(tx.date)
                groupDict[tx.date] = [tx]
            } else {
                groupDict[tx.date]?.append(tx)
            }
        }
        return order.map { date in
            TransactionDateGroup(date: date, transactions: groupDict[date] ?? [])
        }
    }
}
