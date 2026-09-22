import SwiftUI

/// Manages which accounts are tracked as loans and the terms behind each one.
/// Mirrors `CreditCardsSettingsView`: the config it edits rides in the same
/// synced `preferences` table, and a closed account keeps its config but drops
/// out of the list.
struct LoansSettingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var showingAddSheet = false
    /// The loan being edited, carried whole so the editor primes its fields
    /// without a second lookup.
    @State private var editing: (accountId: String, config: LoanConfig)?

    private var configuredLoans: [(account: Account, config: LoanConfig)] {
        let accountsById = Dictionary(uniqueKeysWithValues: budgetStore.accounts.map { ($0.id, $0) })
        return budgetStore.activeLoanConfigs
            .compactMap { accountId, config in
                guard let account = accountsById[accountId] else { return nil }
                return (account: account, config: config)
            }
            .sorted { $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending }
    }

    /// Whether there is any account left to track, which is what decides if
    /// the Add row shows. The editor owns the list itself.
    private var canAddLoan: Bool {
        let configuredIds = Set(budgetStore.loanConfigs.keys)
        return budgetStore.accounts.contains { !$0.closed && !configuredIds.contains($0.id) }
    }

    var body: some View {
        List {
            Section(String(localized: "Configured Loans")) {
                if configuredLoans.isEmpty {
                    Text(String(localized: "Track a loan's balance, interest rate and payoff date, and watch the principal come down as you pay."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    let loans = configuredLoans
                    let detached = budgetStore.syncDetachedByRestore
                    ForEach(loans, id: \.account.id) { item in
                        Button {
                            editing = (item.account.id, item.config)
                        } label: {
                            LoanSummaryRow(account: item.account, config: item.config)
                        }
                        .buttonStyle(.plain)
                        .disabled(detached)
                        .accessibilityIdentifier("loanRow.\(item.account.id)")
                    }
                    .onDelete { offsets in
                        for accountId in offsets.map({ loans[$0].account.id }) {
                            Task { await budgetStore.setLoan(accountId: accountId, config: nil) }
                        }
                    }
                    .deleteDisabled(detached)
                }
            }

            if budgetStore.syncDetachedByRestore {
                Section {
                    Text(String(localized: "Loan settings sync with your budget. Re-download this budget to change them."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if canAddLoan {
                Section {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label(String(localized: "Add Loan"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("loanSettings.add")
                }
            }
        }
        .navigationTitle(String(localized: "Loans"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddSheet) {
            LoanEditorView(mode: .add)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: Binding(
            get: { editing != nil },
            set: {
                if !$0 {
                    editing = nil
                }
            }
        )) {
            if let editing {
                LoanEditorView(mode: .edit(accountId: editing.accountId, config: editing.config))
                    .environmentObject(budgetStore)
            }
        }
    }
}

/// Compact loan row: name and what's still owed on top, payoff summary and
/// progress underneath.
struct LoanSummaryRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account
    let config: LoanConfig

    private var balance: Int {
        budgetStore.accounts.first { $0.id == account.id }?.balance ?? account.balance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name)
                    .fontWeight(.medium)
                Spacer()
                Text(budgetStore.displayBalance(balance))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: config.fractionPaidOff(accountBalance: balance))
                .tint(.accentColor)

            HStack {
                Text(Self.progressText(config.fractionPaidOff(accountBalance: balance)))
                Spacer()
                Text(config.payoffSummary(accountBalance: balance))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "10.0% Paid Off", matching YNAB's own wording on the loan overview.
    nonisolated static func progressText(_ fraction: Double) -> String {
        String(format: String(localized: "%@ Paid Off"), percentText(fraction))
    }

    nonisolated static func percentText(_ fraction: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: fraction)) ?? "0%"
    }
}
