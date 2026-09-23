import Foundation

/// Monthly amortization math for loan accounts.
///
/// Mirrors YNAB's loan model (support.ynab.com, "Loan Accounts"): interest
/// compounds monthly at the annual rate divided by 12 applied to the current
/// balance, and each payment covers that interest — plus escrow or fees where
/// the lender bundles them — before anything reaches principal.
///
/// Every amount is cents, like the rest of the app. What comes back is a
/// projection, not the lender's own schedule: YNAB lets the user correct its
/// estimated interest against what was actually charged, so agreeing with a
/// given lender to the cent is explicitly not a goal here.
enum LoanAmortization {
    /// One projected month.
    struct Entry: Equatable, Sendable {
        let month: DayDate
        /// What is paid this month: the regular payment plus any one-off extra,
        /// or only what's left to clear on the final month.
        let payment: Int
        let interest: Int
        let escrow: Int
        /// The part of `payment` that reduced the balance. Negative when the
        /// payment didn't cover interest and escrow, which is how a loan that
        /// is going backwards shows up.
        let principal: Int
        /// Still owed after this month's payment.
        let balance: Int
    }

    struct Schedule: Equatable, Sendable {
        let entries: [Entry]

        /// The month the final payment lands, or nil for a balance already clear.
        var payoffDate: DayDate? {
            entries.last?.month
        }

        var paymentCount: Int {
            entries.count
        }

        var totalInterest: Int {
            entries.reduce(0) { $0 + $1.interest }
        }

        var totalPaid: Int {
            entries.reduce(0) { $0 + $1.payment }
        }
    }

    /// What paying more than the minimum buys — the headline the loan overview
    /// leads with ("saves you $835.80 in interest ... and you'll pay it off
    /// 1 yr, 3 mos sooner").
    struct Savings: Equatable, Sendable {
        let interest: Int
        let months: Int
    }

    /// Longest projection the engine will run. Fifty years outlives any consumer
    /// loan, and bounding the walk is what lets a payment too small to cover the
    /// interest terminate as nil instead of looping forever.
    static let maxMonths = 600

    /// The interest charged for one month on `balance`.
    ///
    /// Rate ÷ 12 × balance, rounded to the cent. YNAB compounds monthly rather
    /// than applying a daily periodic rate, and matching YNAB matters more here
    /// than matching any particular lender's day-count convention.
    static func monthlyInterest(balance: Int, annualRatePercent: Double) -> Int {
        guard balance > 0, annualRatePercent > 0 else { return 0 }
        // 1200 = 100 (the rate is a percentage) x 12 (months).
        return Int((Double(balance) * annualRatePercent / 1200).rounded())
    }

    /// Projects the loan to payoff, or nil when `payment` can't clear it inside
    /// `maxMonths` — which is what a payment that doesn't cover the monthly
    /// interest looks like from here.
    ///
    /// `extraPayments` are one-off amounts keyed by the month they land in, paid
    /// on top of the regular payment.
    static func schedule(
        balance: Int,
        annualRatePercent: Double,
        payment: Int,
        escrowOrFees: Int = 0,
        extraPayments: [DayDate: Int] = [:],
        startingMonth: DayDate
    ) -> Schedule? {
        guard balance > 0 else { return Schedule(entries: []) }

        var remaining = balance
        var entries: [Entry] = []
        var month = startingMonth

        for _ in 0..<maxMonths {
            let interest = monthlyInterest(balance: remaining, annualRatePercent: annualRatePercent)
            // Interest and escrow come off the top and only the rest touches
            // principal. Capping at what's left is what makes the final month
            // the part-payment that clears the loan rather than an overpayment.
            let due = payment + (extraPayments[month] ?? 0)
            let paid = min(due, remaining + interest + escrowOrFees)
            let principal = paid - interest - escrowOrFees
            remaining -= principal
            entries.append(Entry(
                month: month,
                payment: paid,
                interest: interest,
                escrow: escrowOrFees,
                principal: principal,
                balance: remaining
            ))
            if remaining <= 0 {
                return Schedule(entries: entries)
            }
            month = month.adding(months: 1)
        }
        return nil
    }

    /// The smallest monthly payment that clears `balance` within `months`, or
    /// nil when the term is out of range.
    ///
    /// Searched against `schedule` rather than solved with the annuity formula:
    /// the schedule rounds interest to the cent every month, so a closed-form
    /// answer can miss its own term by a cent. Searching the real thing means
    /// the figure returned is one that demonstrably pays off in time. Payoff
    /// speed only ever rises with payment size, which is what makes the search
    /// valid.
    static func requiredPayment(
        balance: Int,
        annualRatePercent: Double,
        escrowOrFees: Int = 0,
        months: Int,
        startingMonth: DayDate
    ) -> Int? {
        guard balance > 0 else { return 0 }
        guard months > 0, months <= maxMonths else { return nil }

        // Clearing the balance, its first month's interest and the escrow in one
        // go lands inside any term of at least one month, so it bounds the search.
        var low = 1
        var high = balance
            + monthlyInterest(balance: balance, annualRatePercent: annualRatePercent)
            + escrowOrFees
        while low < high {
            let mid = low + (high - low) / 2
            let clears = schedule(
                balance: balance,
                annualRatePercent: annualRatePercent,
                payment: mid,
                escrowOrFees: escrowOrFees,
                startingMonth: startingMonth
            ).map { $0.paymentCount <= months } ?? false
            if clears {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    /// Interest and time saved by following `target` instead of `minimum`.
    static func savings(minimum: Schedule, target: Schedule) -> Savings {
        Savings(
            interest: max(0, minimum.totalInterest - target.totalInterest),
            months: max(0, minimum.paymentCount - target.paymentCount)
        )
    }
}

// MARK: - Burndown

extension LoanAmortization {
    /// One point on the payoff curve.
    struct BalancePoint: Equatable, Sendable, Identifiable {
        let month: DayDate
        let balance: Int

        var id: Int {
            month.yyyymmdd
        }
    }
}

extension LoanAmortization.Schedule {
    /// Balance over time for a burndown chart.
    ///
    /// The opening balance is prepended so the first segment shows the first
    /// month's progress; without it the curve would start already one payment
    /// down and understate the loan.
    func balanceOverTime(openingBalance: Int) -> [LoanAmortization.BalancePoint] {
        guard let first = entries.first else { return [] }
        let opening = LoanAmortization.BalancePoint(
            month: first.month.adding(months: -1),
            balance: openingBalance
        )
        return [opening] + entries.map {
            LoanAmortization.BalancePoint(month: $0.month, balance: $0.balance)
        }
    }
}
