import Foundation

/// A Wallet (FinanceKit) transaction reduced to the fields Actuali imports.
/// Framework-independent so mapping and dedup stay unit-testable — the thin
/// FinanceKit bridge lives in `WalletImportView` (GH #55, Tier 1).
struct WalletImportCandidate: Identifiable, Hashable {
    /// FinanceKit transaction UUID, lowercased — stored as `financial_id`
    /// (Actual's imported_id) for dedup across imports.
    let id: String
    var amountCents: Int   // signed like Transaction.amount (negative = outflow)
    var payeeName: String
    var date: Date
    var cleared: Bool
}

enum WalletImportMapper {

    /// The subset of FinanceKit.TransactionStatus Actuali cares about.
    enum Status {
        case authorized
        case memo
        case pending
        case booked
        case rejected
    }

    /// Map one Wallet transaction to an import candidate.
    /// - Returns: `nil` for rejected transactions (the money never moved) and
    ///   for amounts that don't fit integer cents.
    static func candidate(
        id: UUID,
        amount: Decimal,
        isCredit: Bool,
        merchantName: String?,
        transactionDescription: String,
        status: Status,
        date: Date
    ) -> WalletImportCandidate? {
        guard status != .rejected else { return nil }
        guard let unsignedCents = cents(from: amount) else { return nil }

        // Wallet merchant strings carry the same processor noise as the
        // Shortcuts flow ("SQ *", store numbers) — normalize the same way.
        let rawPayee: String
        if let merchantName, !merchantName.isEmpty {
            rawPayee = merchantName
        } else {
            rawPayee = transactionDescription
        }
        let payee = MerchantNormalizer.normalize(rawPayee)

        return WalletImportCandidate(
            id: id.uuidString.lowercased(),
            amountCents: isCredit ? unsignedCents : -unsignedCents,
            payeeName: payee,
            date: date,
            cleared: status == .booked
        )
    }

    /// Decimal → integer cents, rounding half away from zero (NSDecimalNumber
    /// plain rounding), mirroring `Transaction.cents(fromDollars:)`.
    static func cents(from amount: Decimal) -> Int? {
        let magnitude = amount.magnitude
        let scaled = NSDecimalNumber(decimal: magnitude)
            .multiplying(byPowerOf10: 2)
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            ))
        let value = scaled.doubleValue
        guard value.isFinite, abs(value) <= 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }
}
