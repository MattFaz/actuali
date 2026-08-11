import Foundation

/// Details carried into the add-transaction form by an automation: a failed
/// log-transaction notification tap, or the Add Transaction with Review
/// intent, which opens the form pre-filled for the user to finish (GH #91).
struct TransactionPrefill: Identifiable, Equatable {
    /// Marker key distinguishing our payload from other notifications.
    private static let kind = "com.mfazz.Actuali.transactionPrefill"

    let accountId: String?
    let payee: String
    let amountCents: Int?
    let date: Date
    let notes: String
    let categoryId: String?
    let isIncome: Bool
    let cleared: Bool

    var id: Date { date }

    init(
        accountId: String?,
        payee: String,
        amountCents: Int?,
        date: Date,
        notes: String = "",
        categoryId: String? = nil,
        isIncome: Bool = false,
        cleared: Bool = false
    ) {
        self.accountId = accountId
        self.payee = payee
        self.amountCents = amountCents
        self.date = date
        self.notes = notes
        self.categoryId = categoryId
        self.isIncome = isIncome
        self.cleared = cleared
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["kind"] as? String == Self.kind,
              let timestamp = userInfo["date"] as? Double else { return nil }
        self.accountId = userInfo["accountId"] as? String
        self.payee = userInfo["payee"] as? String ?? ""
        self.amountCents = userInfo["amountCents"] as? Int
        self.date = Date(timeIntervalSince1970: timestamp)
        // Absent on payloads scheduled by older builds; the defaults match
        // what the form used before these fields were carried.
        self.notes = userInfo["notes"] as? String ?? ""
        self.categoryId = userInfo["categoryId"] as? String
        self.isIncome = userInfo["isIncome"] as? Bool ?? false
        self.cleared = userInfo["cleared"] as? Bool ?? false
    }

    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "kind": Self.kind,
            "payee": payee,
            "date": date.timeIntervalSince1970,
            "isIncome": isIncome,
            "cleared": cleared,
        ]
        if let accountId { info["accountId"] = accountId }
        if let amountCents { info["amountCents"] = amountCents }
        if !notes.isEmpty { info["notes"] = notes }
        if let categoryId { info["categoryId"] = categoryId }
        return info
    }
}
