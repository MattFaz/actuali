import SwiftUI

/// View for managing card last-4 digits / bank keyword -> account mappings.
struct CardAccountMappingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @ObservedObject var pendingImportStore: PendingImportStore = .shared
    @State private var showingAddSheet = false
    @State private var newKeyword = ""
    @State private var selectedAccountId = ""
    /// Keyword being edited, if the sheet was opened from an existing row.
    /// Nil means the sheet is adding a new mapping.
    @State private var editingKeyword: String?

    struct CardMappingSuggestion: Identifiable, Equatable {
        var id: String { keyword }
        let keyword: String
        let count: Int
        let samplePayee: String?
    }

    private var sortedMappings: [(keyword: String, accountId: String, accountName: String)] {
        let accountsById = Dictionary(budgetStore.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return budgetStore.cardAccountMappings.map { (keyword, accountId) in
            (keyword: keyword, accountId: accountId, accountName: accountsById[accountId] ?? "Unknown Account")
        }.sorted { $0.keyword < $1.keyword }
    }

    private var suggestedMappings: [CardMappingSuggestion] {
        return Self.computeSuggestions(
            pendingImports: pendingImportStore.imports,
            activeBudgetId: budgetStore.currentBudgetId,
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings
        )
    }

    /// Card hints in pending transactions that do not route anywhere yet.
    /// Reuses the routing chain so the list matches real behavior.
    nonisolated static func computeSuggestions(
        pendingImports: [PendingImport],
        activeBudgetId: String?,
        accounts: [Account],
        cardMappings: [String: String]
    ) -> [CardMappingSuggestion] {
        var grouped: [String: (keyword: String, count: Int, samplePayee: String?)] = [:]
        for item in pendingImports {
            guard item.originBudgetId == nil || item.originBudgetId == activeBudgetId,
                  let hint = item.cardHint?.trimmingCharacters(in: .whitespacesAndNewlines),
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
                                        Text("\(suggestion.count) pending")
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
                        Button {
                            editingKeyword = mapping.keyword
                            newKeyword = mapping.keyword
                            selectedAccountId = mapping.accountId
                            showingAddSheet = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mapping.keyword)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(String(format: String(localized: "Routes to %@"), mapping.accountName))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("cardMappings.row.\(mapping.keyword)")
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
                            // The current target stays selectable even when closed:
                            // mappings to closed accounts are a supported, repairable
                            // state, and an edit must pre-fill with what it edits.
                            ForEach(budgetStore.accounts.filter { !$0.closed || $0.id == selectedAccountId }) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                    } header: {
                        Text(String(localized: "Mapping Details"))
                    } footer: {
                        Text(String(localized: "Enter the digits or keyword exactly as your shortcut passes them in the Card or Account Hint field."))
                    }
                }
                .navigationTitle(editingKeyword == nil
                    ? String(localized: "Add Mapping")
                    : String(localized: "Edit Mapping"))
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
                        .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedAccountId.isEmpty)
                    }
                }
            }
        }
    }

    /// Keywords to remove when saving the sheet. A rename must drop the
    /// original key, otherwise the edit leaves both keywords mapped. Exact
    /// (not case-insensitive) compare: resolution lowercases hints but the
    /// dictionary keys are not merged, so a case-only rename also swaps keys.
    nonisolated static func keywordsRemovedBySave(originalKeyword: String?, cleanedKeyword: String) -> [String] {
        guard let originalKeyword, originalKeyword != cleanedKeyword else { return [] }
        return [originalKeyword]
    }

    private func prepareAndShowAddSheet(keyword: String) {
        selectedAccountId = PendingImportApprover.seedAccountId(
            cardHint: keyword.isEmpty ? nil : keyword,
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings,
            defaultAccountId: budgetStore.defaultAccountId
        ) ?? ""
        newKeyword = keyword
        editingKeyword = nil
        showingAddSheet = true
    }

    private func deleteMapping(at offsets: IndexSet) {
        let keysToDelete = offsets.map { sortedMappings[$0].keyword }
        Task {
            await budgetStore.deleteCardAccountMappings(keywords: keysToDelete)
        }
    }

    private func saveMapping() {
        // Same normalization as BudgetStore.setCardAccountMapping, so the
        // rename comparison below sees the key that will actually be written.
        let cleaned = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !selectedAccountId.isEmpty else { return }
        let accountId = selectedAccountId
        let removed = Self.keywordsRemovedBySave(originalKeyword: editingKeyword, cleanedKeyword: cleaned)
        Task {
            await budgetStore.setCardAccountMapping(keyword: cleaned, accountId: accountId, removingKeywords: removed)
        }
    }
}

#Preview {
    NavigationStack {
        CardAccountMappingsView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
