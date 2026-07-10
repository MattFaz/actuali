import Foundation

/// Details carried on a failed log-transaction notification so tapping it can
/// open the add-transaction form with whatever the automation did receive.
struct TransactionPrefill: Identifiable, Equatable {
    /// Marker key distinguishing our payload from other notifications.
    private static let kind = "com.mfazz.Actuali.transactionPrefill"

    let accountId: String?
    let payee: String
    let amountCents: Int?
    let date: Date

    var id: Date { date }

    init(accountId: String?, payee: String, amountCents: Int?, date: Date) {
        self.accountId = accountId
        self.payee = payee
        self.amountCents = amountCents
        self.date = date
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["kind"] as? String == Self.kind,
              let timestamp = userInfo["date"] as? Double else { return nil }
        self.accountId = userInfo["accountId"] as? String
        self.payee = userInfo["payee"] as? String ?? ""
        self.amountCents = userInfo["amountCents"] as? Int
        self.date = Date(timeIntervalSince1970: timestamp)
    }

    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "kind": Self.kind,
            "payee": payee,
            "date": date.timeIntervalSince1970,
        ]
        if let accountId { info["accountId"] = accountId }
        if let amountCents { info["amountCents"] = amountCents }
        return info
    }
}
