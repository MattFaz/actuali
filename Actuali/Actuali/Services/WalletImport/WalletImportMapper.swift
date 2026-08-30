import Foundation

/// A Wallet (FinanceKit) transaction reduced to the fields Actuali imports.
/// Framework-independent so mapping and dedup stay unit-testable — the thin
/// FinanceKit bridge lives in `FinanceKitWalletStore` (GH #55, Tier 1).
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
    static func candidate(from transaction: AppleWalletTransaction) -> WalletImportCandidate? {
        guard transaction.status != .rejected else { return nil }
        guard let unsignedCents = cents(from: transaction.amount) else { return nil }

        // Wallet merchant strings carry the same processor noise as the
        // Shortcuts flow ("SQ *", store numbers) — normalize the same way.
        let payee = [
            transaction.merchantName.map(MerchantNormalizer.normalize),
            MerchantNormalizer.normalize(transaction.description)
        ].compactMap { $0 }.first { !$0.isEmpty } ?? "Unknown"

        return WalletImportCandidate(
            id: transaction.id,
            amountCents: transaction.isCredit ? unsignedCents : -unsignedCents,
            payeeName: payee,
            date: transaction.date,
            cleared: transaction.status == .booked
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
