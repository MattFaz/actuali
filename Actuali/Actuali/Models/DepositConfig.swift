import Foundation

/// Synced configuration for an interest-earning deposit account, persisted in
/// Actual's `preferences` table under `actuali:deposit:<accountId>` as a JSON
/// string, mirroring `LoanConfig` and `CreditCardConfig`.
///
/// This is the deposit side of the same arithmetic the loan tracker does:
/// money growing on a schedule rather than shrinking. It covers the two shapes
/// banks actually sell — a fixed deposit, where one lump sum sits for a term,
/// and a recurring deposit, where a fixed amount goes in every month for a
/// term. Both compound at a stated frequency and mature on a known date.
///
/// Unlike the loan tracker this has no YNAB counterpart to match: YNAB models
/// no interest-earning deposit instrument at all, so the shape here follows
/// what the products themselves do.
struct DepositConfig: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// One lump sum, left for the term.
        case fixed
        /// A fixed amount deposited every month for the term.
        case recurring
    }

    /// How often interest is credited. Quarterly is the default because it is
    /// what fixed and recurring deposits overwhelmingly use.
    ///
    /// The raw value is compounds per year, and every case divides 12 evenly so
    /// `periodMonths` is exact — the arithmetic counts whole months and never
    /// needs a fractional period.
    enum Compounding: Int, Codable, Sendable, CaseIterable {
        case annually = 1
        case semiAnnually = 2
        case quarterly = 4
        case monthly = 12

        var periodMonths: Int {
            12 / rawValue
        }
    }

    var kind: Kind

    /// In cents. For a fixed deposit this is the lump sum; for a recurring
    /// deposit it is the monthly instalment. One field rather than two because
    /// the kind already says which it is, and two would let them disagree.
    var amount: Int

    /// Nominal annual rate as a percentage — 7.1 means 7.1%.
    var annualRatePercent: Double

    var compounding: Compounding

    /// When the deposit was opened. The maturity date and every intermediate
    /// value are measured from here, so it is stored rather than derived from
    /// the account's first transaction, which a later edit could move.
    var openedOn: DayDate

    /// How long the deposit runs, in months.
    var termMonths: Int

    /// Declared rather than synthesized: Swift only synthesizes `CodingKeys`
    /// when it also synthesizes one of `init(from:)`/`encode(to:)`, and this
    /// type hand-writes both — `init(from:)` for the compounding fallback,
    /// `encode(to:)` to put the opening day on the wire as `YYYYMMDD`.
    /// `LoanConfig` and `CreditCardConfig` only customise decoding, which is
    /// why they still get theirs for free.
    private enum CodingKeys: String, CodingKey {
        case kind, amount, annualRatePercent, compounding, openedOn, termMonths
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
        guard openedOn < date else { return 0 }
        var months = (date.year - openedOn.year) * 12 + (date.month - openedOn.month)
        // Part-way through a month doesn't count: interest credits on whole
        // periods, and a month that hasn't finished hasn't been deposited into.
        if date.day < openedOn.day {
            months -= 1
        }
        return max(0, months)
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
        DepositGrowth.value(self, afterMonths: monthsElapsed(on: date))
    }

    /// What it pays out at the end of the term.
    var maturityValue: Int {
        DepositGrowth.value(self, afterMonths: termMonths)
    }

    /// What has actually gone in by `date` — the lump sum, or the instalments
    /// paid so far. The baseline the interest is measured against.
    func deposited(on date: DayDate = .today()) -> Int {
        DepositGrowth.deposited(self, afterMonths: monthsElapsed(on: date))
    }

    /// Interest credited so far.
    func interestEarned(on date: DayDate = .today()) -> Int {
        value(on: date) - deposited(on: date)
    }

    /// Total interest the deposit pays over its whole term.
    var totalInterest: Int {
        maturityValue - DepositGrowth.deposited(self, afterMonths: termMonths)
    }
}
