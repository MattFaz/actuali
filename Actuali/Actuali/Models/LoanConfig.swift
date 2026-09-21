import Foundation

/// Synced configuration for a loan account, persisted in Actual's `preferences` table.
/// Stored under the key `actuali:loan:<accountId>` as a JSON string, mirroring
/// `CreditCardConfig`.
///
/// The fields are the ones YNAB collects when a loan account is created: the
/// balance owed, the interest rate, the payment the lender requires, and —
/// on a mortgage — whether that payment bundles escrow or fees. A payment
/// target and a paired category come later and decode with `decodeIfPresent`
/// the way `CreditCardConfig` already handles its own later additions, so a
/// client that predates them still reads the rest of the config.
struct LoanConfig: Codable, Equatable, Hashable, Sendable {
    /// What was owed when the loan was added, in cents and always positive.
    /// Payoff progress is measured against this, and the current balance alone
    /// can't recover it.
    ///
    /// ponytail: stored at setup rather than derived from the account's
    /// starting-balance transaction, so it goes stale if that transaction is
    /// later edited. Upgrade path: read the account's oldest transaction and
    /// fall back to this value.
    var originalBalance: Int

    /// Nominal annual rate as a percentage — 5.25 means 5.25% APR.
    var annualRatePercent: Double

    /// The payment the lender requires each month, in cents.
    var minimumPayment: Int

    /// Escrow or fees bundled into the monthly payment, in cents. This is part
    /// of the config rather than a display note because it is covered alongside
    /// interest before anything reaches principal, so it changes the payoff.
    var escrowOrFees: Int?
}

extension LoanConfig {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originalBalance = try container.decode(Int.self, forKey: .originalBalance)
        annualRatePercent = try container.decode(Double.self, forKey: .annualRatePercent)
        minimumPayment = try container.decode(Int.self, forKey: .minimumPayment)
        escrowOrFees = try container.decodeIfPresent(Int.self, forKey: .escrowOrFees)
    }
}
