import Charts
import SwiftUI

/// YNAB's Loan Payoff Simulator: try a payment or a payoff date against a loan
/// and see what it costs. Read-only — nothing here writes a transaction or
/// changes the loan's stored terms.
///
/// The monthly payment is the single source of truth. Picking a payoff date
/// solves back to the payment that reaches it, so the two inputs can't drift
/// out of agreement the way two independent bindings would.
struct LoanPayoffPlannerView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let account: Account
    let config: LoanConfig

    @State private var paymentText: String
    /// A one-off payment on top of this month's, the simulator's "one time extra".
    @State private var extraText = ""

    private let startingMonth: DayDate

    init(account: Account, config: LoanConfig, from month: DayDate = .today()) {
        self.account = account
        self.config = config
        startingMonth = month
        _paymentText = State(initialValue: LoanEditorView.amountText(config.minimumPayment))
    }

    private var balance: Int {
        let live = budgetStore.accounts.first { $0.id == account.id }?.balance ?? account.balance
        return LoanConfig.owed(accountBalance: live)
    }

    /// What the user has typed, falling back to the lender's minimum so the
    /// chart never blanks out mid-edit.
    private var chosenPayment: Int {
        LoanEditorView.cents(from: paymentText).flatMap { $0 > 0 ? $0 : nil } ?? config.minimumPayment
    }

    private var extraPayment: Int {
        LoanEditorView.cents(from: extraText).flatMap { $0 > 0 ? $0 : nil } ?? 0
    }

    private func schedule(payment: Int, extra: Int = 0) -> LoanAmortization.Schedule? {
        LoanAmortization.schedule(
            balance: balance,
            annualRatePercent: config.annualRatePercent,
            payment: payment,
            escrowOrFees: config.escrowOrFees ?? 0,
            extraPayments: extra > 0 ? [startingMonth: extra] : [:],
            startingMonth: startingMonth
        )
    }

    private var minimumSchedule: LoanAmortization.Schedule? {
        schedule(payment: config.minimumPayment)
    }

    private var chosenSchedule: LoanAmortization.Schedule? {
        schedule(payment: chosenPayment, extra: extraPayment)
    }

    /// True when the chosen plan is just the lender's minimum, which is when
    /// the chart has one line to draw rather than a comparison.
    private var isAtMinimum: Bool {
        chosenPayment == config.minimumPayment && extraPayment == 0
    }

    /// Payoff terms the date picker can offer: anything from next month up to
    /// what the lender's minimum already achieves. Paying less than the
    /// minimum isn't the user's to choose, so it isn't offered.
    private var payoffMonthOptions: [Int] {
        guard let count = minimumSchedule?.paymentCount, count > 0 else { return [] }
        return Array(1...count)
    }

    var body: some View {
        NavigationStack {
            List {
                inputsSection
                chartSection
                summarySection
            }
            .navigationTitle(String(localized: "Payoff Simulator"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var inputsSection: some View {
        Section {
            LabeledContent(
                String(localized: "Required Minimum Payment"),
                value: budgetStore.displayBalance(config.minimumPayment)
            )

            HStack {
                Text(String(localized: "Monthly Payment"))
                Spacer()
                AmountInputField(
                    text: $paymentText,
                    conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                    alignment: .right
                )
                .accessibilityIdentifier("loanPlanner.payment")
            }

            if !payoffMonthOptions.isEmpty {
                Picker(String(localized: "Payoff Date"), selection: payoffSelection) {
                    ForEach(payoffMonthOptions, id: \.self) { months in
                        Text(Self.payoffLabel(startingMonth: startingMonth, months: months, locale: locale))
                            .tag(months)
                    }
                }
                .accessibilityIdentifier("loanPlanner.payoffDate")
            }

            HStack {
                Text(Self.extraLabel(month: startingMonth, locale: locale))
                Spacer()
                AmountInputField(
                    text: $extraText,
                    conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                    alignment: .right
                )
                .accessibilityIdentifier("loanPlanner.extra")
            }
        } footer: {
            Text(String(localized: "Raising the payment or adding a one-off shortens the loan and cuts the interest. Nothing here is saved — it only shows what would happen."))
        }
    }

    /// Picking a date writes back to the payment, keeping one source of truth.
    private var payoffSelection: Binding<Int> {
        Binding(
            get: { chosenSchedule?.paymentCount ?? payoffMonthOptions.last ?? 1 },
            set: { months in
                guard let payment = LoanAmortization.requiredPayment(
                    balance: balance,
                    annualRatePercent: config.annualRatePercent,
                    escrowOrFees: config.escrowOrFees ?? 0,
                    months: months,
                    startingMonth: startingMonth
                ) else { return }
                paymentText = LoanEditorView.amountText(payment)
                extraText = ""
            }
        )
    }

    @ViewBuilder private var chartSection: some View {
        if let chosen = chosenSchedule, let minimum = minimumSchedule {
            Section(String(localized: "Balance Over Time")) {
                let chosenPoints = chosen.balanceOverTime(openingBalance: balance)
                let minimumPoints = minimum.balanceOverTime(openingBalance: balance)

                Chart {
                    // The minimum-payment track is the comparison, so it takes
                    // the recessive dashed treatment the forecast widgets use.
                    // Line style carries the difference as well as colour, so
                    // the two are told apart without relying on hue.
                    if !isAtMinimum {
                        ForEach(minimumPoints) { point in
                            LineMark(
                                x: .value(String(localized: "Month"), point.month.utcDate),
                                y: .value(String(localized: "Balance"), Double(point.balance) / 100.0),
                                series: .value(String(localized: "Plan"), String(localized: "Minimum payment"))
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        }
                    }
                    ForEach(chosenPoints) { point in
                        LineMark(
                            x: .value(String(localized: "Month"), point.month.utcDate),
                            y: .value(String(localized: "Balance"), Double(point.balance) / 100.0),
                            series: .value(String(localized: "Plan"), String(localized: "Your payment"))
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(height: 180)
                .chartLegend(isAtMinimum ? .hidden : .visible)
                .modifier(ReportCurrencyYAxis(
                    numberFormat: budgetStore.numberFormat,
                    currencyCode: budgetStore.currencyCode,
                    narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                    locale: locale,
                    hidden: budgetStore.hideBalances
                ))
                .accessibilityHidden(budgetStore.hideBalances)
            }
        }
    }

    @ViewBuilder private var summarySection: some View {
        if let chosen = chosenSchedule {
            Section(String(localized: "Remaining to Pay")) {
                LabeledContent(
                    String(localized: "Principal"),
                    value: budgetStore.displayBalance(balance)
                )
                LabeledContent(
                    String(localized: "Interest Remaining"),
                    value: budgetStore.displayBalance(chosen.totalInterest)
                )
                LabeledContent(
                    String(localized: "Total"),
                    value: budgetStore.displayBalance(balance + chosen.totalInterest)
                )
                LabeledContent(
                    String(localized: "Time Remaining"),
                    value: Self.durationText(months: chosen.paymentCount)
                )

                if let minimum = minimumSchedule, !isAtMinimum {
                    let savings = LoanAmortization.savings(minimum: minimum, target: chosen)
                    Text(Self.savingsText(
                        interest: budgetStore.displayBalance(savings.interest),
                        months: savings.months
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        } else {
            Section {
                Text(String(localized: "Payment doesn't cover interest"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pure text helpers

    /// "Nov 2028" for a term of `months` starting at `startingMonth`, matching
    /// the month the final payment lands in.
    nonisolated static func payoffLabel(
        startingMonth: DayDate,
        months: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let payoff = startingMonth.adding(months: max(0, months - 1))
        return AutomationSentences.monthLabel(
            String(format: "%04d-%02d", payoff.year, payoff.month),
            locale: locale
        )
    }

    /// "One time extra in Dec" — the simulator applies it to the month it opens in.
    nonisolated static func extraLabel(month: DayDate, locale: Locale = .autoupdatingCurrent) -> String {
        let label = AutomationSentences.monthLabel(
            String(format: "%04d-%02d", month.year, month.month),
            locale: locale
        )
        return String(format: String(localized: "One time extra in %@"), label)
    }

    /// "5 yrs, 11 mos" — years first so the headline number is the one that
    /// moves when a payment changes.
    ///
    /// Interpolated rather than `String(format:)` so the catalog's plural
    /// variations resolve: "1 yr" not "1 yrs", and whatever plural forms a
    /// locale has beyond one/other.
    nonisolated static func durationText(months: Int) -> String {
        let years = months / 12
        let remainder = months % 12
        let yearPart = years > 0 ? String(localized: "\(years) yrs") : ""
        let monthPart = remainder > 0 || years == 0 ? String(localized: "\(remainder) mos") : ""
        if yearPart.isEmpty {
            return monthPart
        }
        if monthPart.isEmpty {
            return yearPart
        }
        return "\(yearPart), \(monthPart)"
    }

    nonisolated static func savingsText(interest: String, months: Int) -> String {
        String(
            format: String(localized: "Saves %1$@ in interest and pays the loan off %2$@ sooner."),
            interest,
            durationText(months: months)
        )
    }
}
