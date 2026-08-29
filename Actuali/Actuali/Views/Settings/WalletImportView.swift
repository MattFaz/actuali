import FinanceKit
import FinanceKitUI
import SwiftUI

/// Import Apple Card / Apple Cash / Savings transactions from Wallet via the
/// FinanceKit transaction picker (GH #55, Tier 1). The picker needs no
/// FinanceKit entitlement — the user hand-picks transactions and access is
/// one-time, so this works for any App Store build. Full automatic sync
/// (Tier 2) needs Apple's managed FinanceKit entitlement and lives in bank
/// sync — see `BankSyncSetupView` and `FinanceKitWalletStore`.
struct WalletImportView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    /// Whether this device can offer Wallet transactions at all (Apple Card /
    /// Apple Cash are US-only; unsupported devices hide the entry points).
    static let isSupported = FinanceStore.isDataAvailable(.financialData)

    @State private var selectedAccountId: String?
    @State private var walletSelection: [FinanceKit.Transaction] = []
    @State private var alreadyImportedIds: Set<String> = []
    @State private var isImporting = false
    @State private var result: BudgetStore.WalletImportResult?
    @State private var errorMessage: String?

    init(preselectedAccountId: String? = nil) {
        _selectedAccountId = State(initialValue: preselectedAccountId)
    }

    private var openAccounts: [Account] {
        budgetStore.accounts.filter { !$0.closed }
    }

    /// Wallet selection mapped to import candidates, picker order preserved.
    private var candidates: [WalletImportCandidate] {
        walletSelection.compactMap {
            WalletImportMapper.candidate(from: AppleWalletTransaction($0))
        }
    }

    private var importableCount: Int {
        candidates.filter { !alreadyImportedIds.contains($0.id) }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                if Self.isSupported {
                    accountSection
                    selectionSection
                    if !candidates.isEmpty {
                        candidatesSection
                    }
                    if let result {
                        resultSection(result)
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Section {
                        Text("Wallet transactions aren't available on this device. Apple Card, Apple Cash and Savings are required, and are currently US-only.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import from Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .task(id: selectedAccountId) {
                refreshAlreadyImported()
            }
        }
    }

    private var accountSection: some View {
        Section {
            Picker("Account", selection: $selectedAccountId) {
                Text("Select Account").tag(String?.none)
                ForEach(openAccounts) { account in
                    Text(account.name).tag(Optional(account.id))
                }
            }
        } footer: {
            Text("Transactions you pick from Wallet are added to this account and sync to your Actual server like any other transaction.")
        }
    }

    private var selectionSection: some View {
        Section {
            TransactionPicker(selection: $walletSelection) {
                Label(
                    walletSelection.isEmpty
                        ? "Select Wallet Transactions"
                        : "Change Selection",
                    systemImage: "wallet.pass"
                )
            }
        } footer: {
            Text("Apple shares only the transactions you pick — Actuali has no ongoing access to your Wallet.")
        }
    }

    private var candidatesSection: some View {
        Section {
            ForEach(candidates) { candidate in
                HStack {
                    VStack(alignment: .leading) {
                        Text(candidate.payeeName)
                        Text(candidate.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if alreadyImportedIds.contains(candidate.id) {
                        Text("Imported")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(budgetStore.displayBalance(candidate.amountCents))
                        .foregroundStyle(candidate.amountCents < 0 ? .primary : Color.green)
                }
            }

            Button {
                importNow()
            } label: {
                if isImporting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Import \(importableCount) Transaction\(importableCount == 1 ? "" : "s")")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isImporting || importableCount == 0 || selectedAccountId == nil)
        } header: {
            Text("Selected")
        } footer: {
            if importableCount < candidates.count {
                Text("Transactions marked Imported already exist in this account and will be skipped.")
            }
        }
    }

    private func resultSection(_ result: BudgetStore.WalletImportResult) -> some View {
        Section {
            Label {
                Text(summary(for: result))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func summary(for result: BudgetStore.WalletImportResult) -> String {
        var text = "Imported \(result.imported) transaction\(result.imported == 1 ? "" : "s")"
        if result.skippedDuplicates > 0 {
            text += ", skipped \(result.skippedDuplicates) duplicate\(result.skippedDuplicates == 1 ? "" : "s")"
        }
        return text
    }

    private func importNow() {
        guard let accountId = selectedAccountId else { return }
        let toImport = candidates
        isImporting = true
        errorMessage = nil
        Task {
            do {
                let outcome = try await budgetStore.importWalletTransactions(
                    toImport, accountId: accountId
                )
                result = BudgetStore.WalletImportResult(
                    imported: outcome.imported + (result?.imported ?? 0),
                    skippedDuplicates: outcome.skippedDuplicates + (result?.skippedDuplicates ?? 0)
                )
                walletSelection = []
                refreshAlreadyImported()
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func refreshAlreadyImported() {
        guard let accountId = selectedAccountId else {
            alreadyImportedIds = []
            return
        }
        alreadyImportedIds = budgetStore.walletFinancialIds(accountId: accountId)
    }

}

#Preview {
    WalletImportView()
        .environmentObject(BudgetStore.previewInstance())
}
