import Foundation

/// What a fixed or recurring deposit is worth over its term.
///
/// The deposit-side counterpart to `LoanAmortization`, and deliberately the
/// same shape: pure arithmetic over integer cents with no dependency on the
/// store, so every figure the deposit screens show can be pinned in a test.
///
/// Interest credits on **whole compounding periods**, which is what deposits
/// actually do — a quarterly deposit is worth its principal until the first
/// quarter closes, then steps up. Modelling it as smooth growth would read
/// nicer on a chart and disagree with the bank statement, so it steps.
enum DepositGrowth {
    /// Fifty years, the loan engine's bound too; nothing a bank sells comes
    /// close, and it stops a corrupt term from looping forever.
    static let maxTermMonths = LoanAmortization.maxMonths

    /// Completed periods between two calendar days. Daily, weekly and
    /// bi-weekly compounding use actual elapsed days; longer frequencies use
    /// clamped month anniversaries so Jan 31 + 3 months is one full quarter.
    static func completedPeriods(
        from start: DayDate,
        to end: DayDate,
        compounding: DepositConfig.Compounding
    ) -> Int {
        guard start < end else { return 0 }
        switch compounding.period {
        case .days(let days):
            return start.days(until: end) / days
        case .months(let months):
            return wholeMonthsElapsed(from: start, to: end) / months
        }
    }

    /// Whole calendar months, respecting clamped month-end anniversaries.
    static func wholeMonthsElapsed(from start: DayDate, to end: DayDate) -> Int {
        var months = (end.year - start.year) * 12 + end.month - start.month
        if start.adding(months: months) > end {
            months -= 1
        }
        return max(0, months)
    }

    /// One amount compounded for a number of whole periods.
    private static func compounded(
        _ amount: Int,
        annualRatePercent: Double,
        compounding: DepositConfig.Compounding,
        periods: Int
    ) -> Double {
        guard periods > 0, annualRatePercent > 0 else { return Double(amount) }
        let periodRate = annualRatePercent / 100 / Double(compounding.rawValue)
        return Double(amount) * pow(1 + periodRate, Double(periods))
    }

    /// What `config` is worth once `afterMonths` have elapsed, in cents.
    ///
    /// Clamped to the term at both ends: a deposit is worth its principal on
    /// day one, and a matured one is worth its maturity value and no more —
    /// the money stops earning at maturity rather than compounding forever.
    static func value(_ config: DepositConfig, afterMonths: Int) -> Int {
        value(config, on: config.openedOn.adding(months: afterMonths))
    }

    /// What `config` is worth on a calendar day, in cents.
    static func value(_ config: DepositConfig, on date: DayDate) -> Int {
        let term = min(max(0, config.termMonths), maxTermMonths)
        let maturityDate = config.openedOn.adding(months: term)
        let date = min(max(date, config.openedOn), maturityDate)
        guard config.amount > 0 else { return 0 }

        switch config.kind {
        case .fixed:
            // One lump sum, compounding for as long as it has been in.
            return Int(compounded(
                config.amount,
                annualRatePercent: config.annualRatePercent,
                compounding: config.compounding,
                periods: completedPeriods(from: config.openedOn, to: date, compounding: config.compounding)
            ).rounded())

        case .recurring:
            // Each contribution compounds from the date it was added.
            var total = 0.0
            for instalment in 0..<instalmentsMade(config, on: date) {
                let instalmentDate = contributionDate(config, index: instalment)
                total += compounded(
                    config.amount,
                    annualRatePercent: config.annualRatePercent,
                    compounding: config.compounding,
                    periods: completedPeriods(
                        from: instalmentDate,
                        to: date,
                        compounding: config.compounding
                    )
                )
            }
            return Int(total.rounded())
        }
    }

    /// How many instalments a recurring deposit has taken by `afterMonths`.
    static func instalmentsMade(_ config: DepositConfig, afterMonths: Int) -> Int {
        instalmentsMade(config, on: config.openedOn.adding(months: afterMonths))
    }

    /// Contributions begin on the opening day and repeat until, but not on,
    /// the maturity date. Day-based schedules use fixed elapsed-day intervals;
    /// month-based schedules stay on the opening day's clamped anniversary.
    static func instalmentsMade(_ config: DepositConfig, on date: DayDate) -> Int {
        guard config.kind == .recurring else { return 1 }
        let term = min(max(0, config.termMonths), maxTermMonths)
        guard term > 0 else { return 0 }

        let maturityDate = config.openedOn.adding(months: term)
        let lastEligibleDate = min(max(date, config.openedOn), maturityDate.adding(days: -1))
        let intervals = switch config.contributionFrequency.period {
        case .days(let days):
            config.openedOn.days(until: lastEligibleDate) / days
        case .months(let months):
            wholeMonthsElapsed(from: config.openedOn, to: lastEligibleDate) / months
        }
        return intervals + 1
    }

    private static func contributionDate(_ config: DepositConfig, index: Int) -> DayDate {
        switch config.contributionFrequency.period {
        case .days(let days):
            config.openedOn.adding(days: index * days)
        case .months(let months):
            config.openedOn.adding(months: index * months)
        }
    }

    /// What has gone in by `afterMonths` — the baseline interest is measured
    /// against, and the figure that makes a zero-rate deposit read as exactly
    /// what was paid into it.
    static func deposited(_ config: DepositConfig, afterMonths: Int) -> Int {
        deposited(config, on: config.openedOn.adding(months: afterMonths))
    }

    static func deposited(_ config: DepositConfig, on date: DayDate) -> Int {
        guard config.amount > 0 else { return 0 }
        switch config.kind {
        case .fixed:
            // The lump sum is in from day one, whatever the term says.
            return config.amount
        case .recurring:
            return config.amount * instalmentsMade(config, on: date)
        }
    }
}

// MARK: - Growth curve

extension DepositGrowth {
    /// One point on the growth curve.
    struct Point: Equatable, Sendable, Identifiable {
        let month: DayDate
        let value: Int
        /// What had been paid in by this point, so a chart can show the
        /// interest as the gap between the two rather than as a third series.
        let deposited: Int

        var id: Int {
            month.yyyymmdd
        }
    }

    /// Month-by-month value from opening to maturity, for a growth chart.
    ///
    /// One point per month including both ends, so a five-year deposit is 61
    /// points — small enough to hand straight to Swift Charts.
    static func curve(_ config: DepositConfig) -> [Point] {
        let term = min(max(0, config.termMonths), maxTermMonths)
        guard term > 0, config.amount > 0 else { return [] }
        return (0...term).map { month in
            Point(
                month: config.openedOn.adding(months: month),
                value: value(config, afterMonths: month),
                deposited: deposited(config, afterMonths: month)
            )
        }
    }
}
