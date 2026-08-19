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
            (keyword: keyword, accountName: accountsById[accountId] ?? String(localized: "Unknown Account"))
        }.sorted { $0.keyword < $1.keyword }
    }

    var body: some View {
        List {
            Section {
                Text(String(localized: "cardMappings.explanation"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "cardMappings.title")) {
                if sortedMappings.isEmpty {
                    Text(String(localized: "cardMappings.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedMappings, id: \.keyword) { mapping in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mapping.keyword)
                                    .font(.headline)
                                Text(String(format: String(localized: "cardMappings.routesTo"), mapping.accountName))
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
                    Label(String(localized: "cardMappings.add"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(String(localized: "cardMappings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField(String(localized: "cardMappings.keywordPrompt"), text: $newKeyword)
                            .autocorrectionDisabled()
                        
                        Picker(String(localized: "cardMappings.targetAccount"), selection: $selectedAccountId) {
                            ForEach(budgetStore.accounts.filter { !$0.closed }) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                    } header: {
                        Text(String(localized: "cardMappings.details"))
                    } footer: {
                        Text(String(localized: "cardMappings.footer"))
                    }
                }
                .navigationTitle(String(localized: "cardMappings.addTitle"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "common.cancel")) { showingAddSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "common.save")) {
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
