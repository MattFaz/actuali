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

// MARK: - Payoff progress

extension LoanConfig {
    /// What is still owed, as a positive number. Actual holds a loan balance
    /// negative while money is owed, the same convention `availableCredit`
    /// relies on for cards, so the sign is flipped here once rather than at
    /// every call site.
    nonisolated static func owed(accountBalance: Int) -> Int {
        max(0, -accountBalance)
    }

    /// Principal repaid so far, in cents. Clamped at both ends: a balance that
    /// grew past the original (an early loan where interest outruns payments)
    /// reads as nothing repaid rather than a negative, and one overpaid past
    /// zero can't exceed the original.
    func paidOff(accountBalance: Int) -> Int {
        min(originalBalance, max(0, originalBalance - Self.owed(accountBalance: accountBalance)))
    }

    /// Share of the original balance repaid, 0...1 — the "10.0% Paid Off" ring.
    /// A zero original balance has no meaningful progress, so it reads as 0
    /// rather than dividing by zero.
    func fractionPaidOff(accountBalance: Int) -> Double {
        guard originalBalance > 0 else { return 0 }
        return Double(paidOff(accountBalance: accountBalance)) / Double(originalBalance)
    }

    /// The projection for this loan against `accountBalance`, at whichever
    /// payment is in force. nil when the payment can't clear the balance —
    /// see `LoanAmortization.schedule`.
    func schedule(accountBalance: Int, from month: DayDate = .today()) -> LoanAmortization.Schedule? {
        LoanAmortization.schedule(
            balance: Self.owed(accountBalance: accountBalance),
            annualRatePercent: annualRatePercent,
            payment: minimumPayment,
            escrowOrFees: escrowOrFees ?? 0,
            startingMonth: month
        )
    }

    /// One-line payoff summary, shared by the Loans list and the account
    /// header so the two can't word the same fact differently — the same
    /// contract `CreditCardCycle.dueSummary` holds for cards.
    ///
    /// A payment too small to cover the monthly interest has no payoff date to
    /// show. That says so rather than showing nothing: a loan going backwards
    /// is the case most worth surfacing.
    func payoffSummary(
        accountBalance: Int,
        from month: DayDate = .today(),
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard Self.owed(accountBalance: accountBalance) > 0 else {
            return String(localized: "Paid off")
        }
        guard let payoff = schedule(accountBalance: accountBalance, from: month)?.payoffDate else {
            return String(localized: "Payment doesn't cover interest")
        }
        let label = AutomationSentences.monthLabel(
            String(format: "%04d-%02d", payoff.year, payoff.month),
            locale: locale
        )
        return String(format: String(localized: "Paid off %@"), label)
    }
}
