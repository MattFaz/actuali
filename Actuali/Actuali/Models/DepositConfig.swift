import Foundation

/// Synced configuration for an interest-earning deposit account, persisted in
/// Actual's `preferences` table under `actuali:deposit:<accountId>` as a JSON
/// string, mirroring `LoanConfig` and `CreditCardConfig`.
///
/// This is the deposit side of the same arithmetic the loan tracker does:
/// money growing on a schedule rather than shrinking. It covers the two shapes
/// banks actually sell — a fixed deposit, where one lump sum sits for a term,
/// and a recurring deposit, where a fixed amount goes in at a chosen interval
/// for a term. Contributions and interest compounding have separate frequencies.
///
/// Unlike the loan tracker this has no YNAB counterpart to match: YNAB models
/// no interest-earning deposit instrument at all, so the shape here follows
/// what the products themselves do.
struct DepositConfig: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// One lump sum, left for the term.
        case fixed
        /// A fixed amount deposited at a chosen interval for the term.
        case recurring
    }

    /// A schedule interval is expressed in one unit, never an optional pair.
    enum Period: Equatable, Sendable {
        case days(Int)
        case months(Int)
    }

    /// How often recurring deposits are contributed. The first contribution
    /// is made on the opening day, then repeats at this interval.
    enum ContributionFrequency: String, Codable, Sendable, CaseIterable {
        case weekly
        case biWeekly
        case monthly
        case quarterly
        case annually

        var period: Period {
            switch self {
            case .weekly: .days(7)
            case .biWeekly: .days(14)
            case .monthly: .months(1)
            case .quarterly: .months(3)
            case .annually: .months(12)
            }
        }
    }

    /// How often interest is credited. Quarterly remains the default.
    ///
    /// The raw value is compounding periods per year, which is also the
    /// denominator used for the nominal annual rate.
    enum Compounding: Int, Codable, Sendable, CaseIterable {
        case daily = 365
        case weekly = 52
        case biWeekly = 26
        case monthly = 12
        case quarterly = 4
        case semiAnnually = 2
        case annually = 1

        var period: Period {
            switch self {
            case .daily: .days(1)
            case .weekly: .days(7)
            case .biWeekly: .days(14)
            case .monthly: .months(1)
            case .quarterly: .months(3)
            case .semiAnnually: .months(6)
            case .annually: .months(12)
            }
        }
    }

    var kind: Kind

    /// In cents. For a fixed deposit this is the lump sum; for a recurring
    /// deposit it is the contribution amount at the selected frequency. One
    /// field rather than two because the kind already says which it is.
    var amount: Int

    /// Nominal annual rate as a percentage — 7.1 means 7.1%.
    var annualRatePercent: Double

    var compounding: Compounding

    /// How often money is added to a recurring deposit. Older saved deposits
    /// predate this setting and continue to use monthly contributions.
    var contributionFrequency: ContributionFrequency = .monthly

    /// When the deposit was opened. The maturity date and every intermediate
    /// value are measured from here, so it is stored rather than derived from
    /// the account's first transaction, which a later edit could move.
    var openedOn: DayDate

    /// How long the deposit runs, in months.
    var termMonths: Int

    /// Declared because both `init(from:)` and `encode(to:)` are hand-written.
    private enum CodingKeys: String, CodingKey {
        case kind, amount, annualRatePercent, compounding, contributionFrequency, openedOn, termMonths
    }
}

extension DepositConfig {
    /// `openedOn` crosses the wire as a `YYYYMMDD` integer — Actual's own date
    /// convention, and the one every other date in this database uses. That
    /// keeps `DayDate` free of a `Codable` conformance it would only need here.
    ///
    /// The compounding frequency falls back to quarterly when it is missing or
    /// unrecognised — `try?` rather than `decodeIfPresent`, which would throw
    /// on a value that is present but from a newer client. That is the same
    /// forward compatibility `CreditCardConfig` and `LoanConfig` keep for
    /// their own later fields: losing the frequency costs precision, failing
    /// the decode loses the account's tracking entirely.
    ///
    /// A missing or impossible opening date is not recoverable that way —
    /// every figure is measured from it — so that does throw.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        amount = try container.decode(Int.self, forKey: .amount)
        annualRatePercent = try container.decode(Double.self, forKey: .annualRatePercent)
        compounding = (try? container.decode(Compounding.self, forKey: .compounding)) ?? .quarterly
        contributionFrequency = (try? container.decode(
            ContributionFrequency.self, forKey: .contributionFrequency
        )) ?? .monthly
        termMonths = try container.decode(Int.self, forKey: .termMonths)

        let opened = try container.decode(Int.self, forKey: .openedOn)
        guard let day = DayDate(yyyymmdd: opened) else {
            throw DecodingError.dataCorruptedError(
                forKey: .openedOn, in: container,
                debugDescription: "openedOn must be a valid YYYYMMDD date"
            )
        }
        openedOn = day
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(amount, forKey: .amount)
        try container.encode(annualRatePercent, forKey: .annualRatePercent)
        try container.encode(compounding, forKey: .compounding)
        try container.encode(contributionFrequency, forKey: .contributionFrequency)
        try container.encode(openedOn.yyyymmdd, forKey: .openedOn)
        try container.encode(termMonths, forKey: .termMonths)
    }
}

// MARK: - Dates and progress

extension DepositConfig {
    /// The day the deposit matures.
    var maturityDate: DayDate {
        openedOn.adding(months: max(0, termMonths))
    }

    /// Whole months from opening to `date`, floored at zero. A date before the
    /// deposit opened reads as month zero rather than a negative term.
    func monthsElapsed(on date: DayDate = .today()) -> Int {
        DepositGrowth.wholeMonthsElapsed(from: openedOn, to: date)
    }

    /// Months still to run, floored at zero once matured.
    func monthsRemaining(on date: DayDate = .today()) -> Int {
        max(0, termMonths - monthsElapsed(on: date))
    }

    func hasMatured(on date: DayDate = .today()) -> Bool {
        monthsElapsed(on: date) >= termMonths
    }

    /// Share of the term completed, 0...1 — the progress bar. A zero-month
    /// term is already over rather than dividing by zero.
    func fractionElapsed(on date: DayDate = .today()) -> Double {
        guard termMonths > 0 else { return 1 }
        return min(1, Double(monthsElapsed(on: date)) / Double(termMonths))
    }
}

// MARK: - Value

extension DepositConfig {
    /// What the deposit is worth on `date`, in cents.
    func value(on date: DayDate = .today()) -> Int {
        DepositGrowth.value(self, on: date)
    }

    /// What it pays out at the end of the term.
    var maturityValue: Int {
        DepositGrowth.value(self, on: maturityDate)
    }

    /// What has actually gone in by `date` — the lump sum, or the instalments
    /// paid so far. The baseline the interest is measured against.
    func deposited(on date: DayDate = .today()) -> Int {
        DepositGrowth.deposited(self, on: date)
    }

    /// Interest credited so far.
    func interestEarned(on date: DayDate = .today()) -> Int {
        value(on: date) - deposited(on: date)
    }

    /// Total interest the deposit pays over its whole term.
    var totalInterest: Int {
        maturityValue - DepositGrowth.deposited(self, on: maturityDate)
    }
}
