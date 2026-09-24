import SwiftUI

/// Manages which accounts are tracked as deposits and the terms behind each
/// one. The deposit-side twin of `LoansSettingsView`, down to the synced
/// `preferences` storage and a closed account keeping its config while
/// dropping out of the list.
struct DepositsSettingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var showingAddSheet = false
    /// The deposit being edited, carried whole so the editor primes its fields
    /// without a second lookup.
    @State private var editing: (accountId: String, config: DepositConfig)?

    private var configuredDeposits: [(account: Account, config: DepositConfig)] {
        let accountsById = Dictionary(uniqueKeysWithValues: budgetStore.accounts.map { ($0.id, $0) })
        return budgetStore.activeDepositConfigs
            .compactMap { accountId, config in
                guard let account = accountsById[accountId] else { return nil }
                return (account: account, config: config)
            }
            .sorted { $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending }
    }

    /// Whether there is any account left to track, which is what decides if
    /// the Add row shows. The editor owns the list itself.
    private var canAddDeposit: Bool {
        let configuredIds = Set(budgetStore.depositConfigs.keys)
        return budgetStore.accounts.contains { !$0.closed && !configuredIds.contains($0.id) }
    }

    var body: some View {
        List {
            Section(String(localized: "Configured Deposits")) {
                if configuredDeposits.isEmpty {
                    Text(String(localized: "Track a fixed or recurring deposit's term, rate and maturity, and watch the interest build up."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    let deposits = configuredDeposits
                    let detached = budgetStore.syncDetachedByRestore
                    ForEach(deposits, id: \.account.id) { item in
                        Button {
                            editing = (item.account.id, item.config)
                        } label: {
                            DepositSummaryRow(account: item.account, config: item.config)
                        }
                        .buttonStyle(.plain)
                        .disabled(detached)
                        .accessibilityIdentifier("depositRow.\(item.account.id)")
                    }
                    .onDelete { offsets in
                        for accountId in offsets.map({ deposits[$0].account.id }) {
                            Task { await budgetStore.setDeposit(accountId: accountId, config: nil) }
                        }
                    }
                    .deleteDisabled(detached)
                }
            }

            if budgetStore.syncDetachedByRestore {
                Section {
                    Text(String(localized: "Deposit settings sync with your budget. Re-download this budget to change them."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if canAddDeposit {
                Section {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label(String(localized: "Add Deposit"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("depositSettings.add")
                }
            }
        }
        .navigationTitle(String(localized: "Deposits"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddSheet) {
            DepositEditorView(mode: .add)
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
                DepositEditorView(mode: .edit(accountId: editing.accountId, config: editing.config))
                    .environmentObject(budgetStore)
            }
        }
    }
}

/// Compact deposit row: name and what it is worth today on top, maturity and
/// progress through the term underneath.
struct DepositSummaryRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let account: Account
    let config: DepositConfig
    var today: DayDate = .today()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name)
                    .fontWeight(.medium)
                Spacer()
                Text(budgetStore.displayBalance(config.value(on: today)))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: config.fractionElapsed(on: today))
                .tint(.accentColor)

            HStack {
                Text(LoanSummaryRow.percentText(config.annualRatePercent / 100))
                Spacer()
                Text(Self.maturitySummary(config, on: today))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "Matures 15 Jan 2028", or "Matured" once the term is up — the deposit
    /// keeps its row after maturity because it still has a final value.
    nonisolated static func maturitySummary(_ config: DepositConfig, on today: DayDate = .today()) -> String {
        guard !config.hasMatured(on: today) else { return String(localized: "Matured") }
        return String(
            format: String(localized: "Matures %@"),
            config.maturityDate.utcDate.formatted(date: .abbreviated, time: .omitted)
        )
    }
}
