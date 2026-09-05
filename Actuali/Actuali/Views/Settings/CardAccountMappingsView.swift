import SwiftUI

/// View for managing card last-4 digits / bank keyword -> account mappings.
struct CardAccountMappingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var showingAddSheet = false
    @State private var newKeyword = ""
    @State private var selectedAccountId = ""

    private var sortedMappings: [(keyword: String, accountName: String)] {
        let accountsById = Dictionary(budgetStore.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return budgetStore.cardAccountMappings.map { (keyword, accountId) in
            (keyword: keyword, accountName: accountsById[accountId] ?? "Unknown Account")
        }.sorted { $0.keyword < $1.keyword }
    }

    var body: some View {
        List {
            Section {
                Text("Map card last-4 digits or bank keywords (e.g. \"1234\", \"HSBC\") to your accounts. When a shortcut logs a transaction with a card or account hint — such as the card name from an Apple Wallet automation — it routes to the matching account automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Card Mappings") {
                if sortedMappings.isEmpty {
                    Text("No card mappings added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedMappings, id: \.keyword) { mapping in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mapping.keyword)
                                    .font(.headline)
                                Text("Routes to \(mapping.accountName)")
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
                        TextField("Card Last-4 or Keyword (e.g. 1234, HSBC)", text: $newKeyword)
                            .autocorrectionDisabled()
                        
                        Picker("Target Account", selection: $selectedAccountId) {
                            ForEach(budgetStore.accounts.filter { !$0.closed }) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                    } header: {
                        Text("Mapping Details")
                    } footer: {
                        Text("Enter the digits or keyword exactly as your shortcut passes them in the Card or Account Hint field.")
                    }
                }
                .navigationTitle("Add Mapping")
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
