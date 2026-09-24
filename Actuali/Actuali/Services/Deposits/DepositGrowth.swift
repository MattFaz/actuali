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
    /// Fifty years. Matches `LoanAmortization.maxMonths`; nothing a bank sells
    /// comes close, and it stops a corrupt term from looping forever.
    static let maxTermMonths = 600

    /// Compounding periods completed after `months` have elapsed.
    static func completedPeriods(afterMonths months: Int, compounding: DepositConfig.Compounding) -> Int {
        guard months > 0 else { return 0 }
        return months / compounding.periodMonths
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
        let term = min(max(0, config.termMonths), maxTermMonths)
        let months = min(max(0, afterMonths), term)
        guard config.amount > 0 else { return 0 }

        switch config.kind {
        case .fixed:
            // One lump sum, compounding for as long as it has been in.
            return Int(compounded(
                config.amount,
                annualRatePercent: config.annualRatePercent,
                compounding: config.compounding,
                periods: completedPeriods(afterMonths: months, compounding: config.compounding)
            ).rounded())

        case .recurring:
            // Each instalment compounds only for the time since it was paid,
            // so they can't share one exponent — the first has the whole term
            // behind it and the last has barely a month.
            var total = 0.0
            for instalment in 0..<instalmentsMade(config, afterMonths: months) {
                total += compounded(
                    config.amount,
                    annualRatePercent: config.annualRatePercent,
                    compounding: config.compounding,
                    periods: completedPeriods(
                        afterMonths: months - instalment,
                        compounding: config.compounding
                    )
                )
            }
            return Int(total.rounded())
        }
    }

    /// How many instalments a recurring deposit has taken by `afterMonths`.
    /// The first goes in on the opening day, so month 0 already has one.
    static func instalmentsMade(_ config: DepositConfig, afterMonths: Int) -> Int {
        guard config.kind == .recurring else { return 1 }
        let term = min(max(0, config.termMonths), maxTermMonths)
        guard term > 0 else { return 0 }
        return min(max(0, afterMonths) + 1, term)
    }

    /// What has gone in by `afterMonths` — the baseline interest is measured
    /// against, and the figure that makes a zero-rate deposit read as exactly
    /// what was paid into it.
    static func deposited(_ config: DepositConfig, afterMonths: Int) -> Int {
        guard config.amount > 0 else { return 0 }
        switch config.kind {
        case .fixed:
            // The lump sum is in from day one, whatever the term says.
            return config.amount
        case .recurring:
            return config.amount * instalmentsMade(config, afterMonths: afterMonths)
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
