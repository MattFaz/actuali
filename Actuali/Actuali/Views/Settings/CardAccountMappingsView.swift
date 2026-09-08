import SwiftUI

/// View for managing card last-4 digits / bank keyword -> account mappings.
struct CardAccountMappingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var showingAddSheet = false
    @State private var newKeyword = ""
    @State private var selectedAccountId = ""

    private var sortedMappings: [(keyword: String, accountName: String)] {
        let accountsById = Dictionary(uniqueKeysWithValues: budgetStore.accounts.map { ($0.id, $0.name) })
        return budgetStore.cardAccountMappings.map { (keyword, accountId) in
            (keyword: keyword, accountName: accountsById[accountId] ?? "Unknown Account")
        }.sorted { $0.keyword < $1.keyword }
    }

    var body: some View {
        List {
            Section {
                Text(String(localized: "Map card last-4 digits or bank keywords (e.g. \"1234\", \"HSBC\") to your accounts. When a shortcut logs a transaction with a card or account hint — such as the card name from an Apple Wallet automation — it routes to the matching account automatically."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    if let firstAccount = budgetStore.accounts.first(where: { !$0.closed }) {
                        selectedAccountId = firstAccount.id
                    }
                    newKeyword = ""
                    showingAddSheet = true
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

    private func deleteMapping(at offsets: IndexSet) {
        var mappings = budgetStore.cardAccountMappings
        for index in offsets {
            let key = sortedMappings[index].keyword
            mappings.removeValue(forKey: key)
        }
        budgetStore.cardAccountMappings = mappings
    }

    private func saveMapping() {
        let cleaned = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, !selectedAccountId.isEmpty else { return }
        var mappings = budgetStore.cardAccountMappings
        mappings[cleaned] = selectedAccountId
        budgetStore.cardAccountMappings = mappings
    }
}

#Preview {
    NavigationStack {
        CardAccountMappingsView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
