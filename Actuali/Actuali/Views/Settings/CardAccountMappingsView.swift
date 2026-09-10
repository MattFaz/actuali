import SwiftUI

/// View for managing card last-4 digits / bank keyword -> account mappings.
struct CardAccountMappingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @ObservedObject var pendingImportStore: PendingImportStore = .shared
    @State private var showingAddSheet = false
    @State private var newKeyword = ""
    @State private var selectedAccountId = ""

    struct CardMappingSuggestion: Identifiable, Equatable {
        var id: String { keyword }
        let keyword: String
        let count: Int
        let samplePayee: String?
    }

    private var sortedMappings: [(keyword: String, accountName: String)] {
        let accountsById = Dictionary(budgetStore.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return budgetStore.cardAccountMappings.map { (keyword, accountId) in
            (keyword: keyword, accountName: accountsById[accountId] ?? "Unknown Account")
        }.sorted { $0.keyword < $1.keyword }
    }

    private var suggestedMappings: [CardMappingSuggestion] {
        let budgetId = budgetStore.currentBudgetId
        return Self.computeSuggestions(
            pendingImports: pendingImportStore.imports.filter {
                $0.originBudgetId == nil || $0.originBudgetId == budgetId
            },
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings
        )
    }

    /// Card hints in pending transactions that do not route anywhere yet.
    /// Reuses the routing chain so the list matches real behavior.
    nonisolated static func computeSuggestions(
        pendingImports: [PendingImport],
        accounts: [Account],
        cardMappings: [String: String]
    ) -> [CardMappingSuggestion] {
        var grouped: [String: (keyword: String, count: Int, samplePayee: String?)] = [:]
        for item in pendingImports {
            guard let hint = item.cardHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !hint.isEmpty,
                  BudgetStore.resolveAccountId(
                      hint: hint, accounts: accounts, cardMappings: cardMappings) == nil else {
                continue
            }
            let key = hint.lowercased()
            let existing = grouped[key]
            grouped[key] = (
                existing?.keyword ?? hint,
                (existing?.count ?? 0) + 1,
                existing?.samplePayee ?? item.payee
            )
        }

        return grouped.values.map {
            CardMappingSuggestion(keyword: $0.keyword, count: $0.count, samplePayee: $0.samplePayee)
        }.sorted {
            $0.count != $1.count
                ? $0.count > $1.count
                : $0.keyword.localizedCaseInsensitiveCompare($1.keyword) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                Text(String(localized: "Map card last-4 digits or bank keywords (e.g. \"1234\", \"HSBC\") to your accounts. When a shortcut logs a transaction with a card or account hint — such as the card name from an Apple Wallet automation — it routes to the matching account automatically."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !suggestedMappings.isEmpty {
                Section {
                    ForEach(suggestedMappings) { suggestion in
                        Button {
                            prepareAndShowAddSheet(keyword: suggestion.keyword)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(suggestion.keyword)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text(String(format: String(localized: "%lld pending"), Int64(suggestion.count)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let payee = suggestion.samplePayee, !payee.isEmpty {
                                        Text(payee)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .font(.body)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "Suggestions"))
                } footer: {
                    Text(String(localized: "Unmapped cards found in pending transactions. Tap to create a mapping."))
                }
            }

            Section(String(localized: "Card Mappings")) {
                if sortedMappings.isEmpty {
                    Text(String(localized: "No card mappings added yet."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedMappings, id: \.keyword) { mapping in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mapping.keyword)
                                    .font(.headline)
                                Text(String(format: String(localized: "Routes to %@"), mapping.accountName))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete(perform: deleteMapping)
                }
            }

            Section {
                Button {
                    prepareAndShowAddSheet(keyword: "")
                } label: {
                    Label("Add Card Mapping", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Card Mappings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField(String(localized: "Card Last-4 or Keyword (e.g. 1234, HSBC)"), text: $newKeyword)
                            .autocorrectionDisabled()
                        
                        Picker(String(localized: "Target Account"), selection: $selectedAccountId) {
                            ForEach(budgetStore.accounts.filter { !$0.closed }) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                    } header: {
                        Text(String(localized: "Mapping Details"))
                    } footer: {
                        Text(String(localized: "Enter the digits or keyword exactly as your shortcut passes them in the Card or Account Hint field."))
                    }
                }
                .navigationTitle(String(localized: "Add Mapping"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAddSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveMapping()
                            showingAddSheet = false
                        }
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty || selectedAccountId.isEmpty)
                    }
                }
            }
        }
    }

    private func prepareAndShowAddSheet(keyword: String) {
        selectedAccountId = PendingImportApprover.seedAccountId(
            cardHint: keyword.isEmpty ? nil : keyword,
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings,
            defaultAccountId: budgetStore.defaultAccountId
        ) ?? ""
        newKeyword = keyword
        showingAddSheet = true
    }

    private func deleteMapping(at offsets: IndexSet) {
        let keysToDelete = offsets.map { sortedMappings[$0].keyword }
        Task {
            await budgetStore.deleteCardAccountMappings(keywords: keysToDelete)
        }
    }

    private func saveMapping() {
        let cleaned = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, !selectedAccountId.isEmpty else { return }
        let accountId = selectedAccountId
        Task {
            await budgetStore.setCardAccountMapping(keyword: cleaned, accountId: accountId)
        }
    }
}

#Preview {
    NavigationStack {
        CardAccountMappingsView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
