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
        Self.computeSuggestions(
            pendingImports: pendingImportStore.imports,
            cardMappings: budgetStore.cardAccountMappings
        )
    }

    /// Finds unmapped card hints present in pending transactions.
    /// ponytail: Deduplicate case-insensitively; skip hints that match any existing
    /// keyword or exact keyword. Sort by highest frequency then alphabetically.
    nonisolated static func computeSuggestions(
        pendingImports: [PendingImport],
        cardMappings: [String: String]
    ) -> [CardMappingSuggestion] {
        let mappedKeys = Set(
            cardMappings.keys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        var grouped: [String: (originalKeyword: String, count: Int, samplePayee: String?)] = [:]
        for item in pendingImports {
            guard let rawHint = item.cardHint?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHint.isEmpty else {
                continue
            }
            let lowerHint = rawHint.lowercased()
            guard !mappedKeys.contains(where: { key in lowerHint == key || lowerHint.contains(key) }) else {
                continue
            }

            if let existing = grouped[lowerHint] {
                grouped[lowerHint] = (
                    originalKeyword: existing.originalKeyword,
                    count: existing.count + 1,
                    samplePayee: existing.samplePayee ?? item.payee
                )
            } else {
                grouped[lowerHint] = (
                    originalKeyword: rawHint,
                    count: 1,
                    samplePayee: item.payee
                )
            }
        }

        return grouped.values.map {
            CardMappingSuggestion(
                keyword: $0.originalKeyword,
                count: $0.count,
                samplePayee: $0.samplePayee
            )
        }.sorted { first, second in
            if first.count != second.count {
                return first.count > second.count
            }
            return first.keyword.localizedCaseInsensitiveCompare(second.keyword) == .orderedAscending
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
                            selectSuggestion(suggestion)
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

    private func selectSuggestion(_ suggestion: CardMappingSuggestion) {
        prepareAndShowAddSheet(keyword: suggestion.keyword)
    }

    private func prepareAndShowAddSheet(keyword: String) {
        if let defaultId = budgetStore.defaultAccountId,
           budgetStore.accounts.contains(where: { $0.id == defaultId && !$0.closed }) {
            selectedAccountId = defaultId
        } else if let firstAccount = budgetStore.accounts.first(where: { !$0.closed }) {
            selectedAccountId = firstAccount.id
        }
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
