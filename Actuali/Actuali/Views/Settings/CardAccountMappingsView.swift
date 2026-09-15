import SwiftUI

/// View for managing card last-4 digits / bank keyword -> account mappings.
struct CardAccountMappingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @ObservedObject var pendingImportStore: PendingImportStore = .shared
    @State private var showingSheet = false
    @State private var keywords: [String] = [""]
    @State private var originalKeywords: [String] = []
    @State private var selectedAccountId = ""
    @State private var isEditing = false

    struct CardMappingSuggestion: Identifiable, Equatable {
        var id: String { keyword }
        let keyword: String
        let count: Int
        let samplePayee: String?
    }

    struct MappedAccount: Identifiable, Equatable {
        var id: String { accountId }
        let accountId: String
        let accountName: String
        let keywords: [String]
    }

    private var mappedAccounts: [MappedAccount] {
        let accountsById = Dictionary(budgetStore.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var keywordsByAccount: [String: [String]] = [:]
        for (keyword, accountId) in budgetStore.cardAccountMappings {
            keywordsByAccount[accountId, default: []].append(keyword)
        }
        return keywordsByAccount.map { (accountId, keywords) in
            MappedAccount(
                accountId: accountId,
                accountName: accountsById[accountId] ?? String(localized: "Unknown Account"),
                keywords: keywords.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            )
        }.sorted { $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending }
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

    private var cleanedKeywords: [String] {
        keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        List {
            Section {
                Text(String(localized: "cardMappings.explanation"))
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

            Section(String(localized: "cardMappings.title")) {
                if mappedAccounts.isEmpty {
                    Text(String(localized: "cardMappings.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mappedAccounts) { item in
                        Button {
                            prepareAndShowEditSheet(accountId: item.accountId, keywords: item.keywords)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.accountName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    FlowLayout(spacing: 6) {
                                        ForEach(item.keywords, id: \.self) { keyword in
                                            Text(keyword)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color(.secondarySystemFill), in: Capsule())
                                                .accessibilityIdentifier("cardMappings.badge.\(keyword)")
                                        }
                                    }
                                }
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("cardMappings.row.\(item.keywords.first ?? item.accountId)")
                    }
                    .onDelete(perform: deleteAccountMapping)
                }
            }

            Section {
                Button {
                    prepareAndShowAddSheet(keyword: "")
                } label: {
                    Label(String(localized: "cardMappings.add"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(String(localized: "cardMappings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSheet) {
            NavigationStack {
                Form {
                    Section {
                        Picker(String(localized: "cardMappings.targetAccount"), selection: $selectedAccountId) {
                            ForEach(budgetStore.accounts.filter { !$0.closed || $0.id == selectedAccountId }) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                        .accessibilityIdentifier("cardMappings.accountPicker")
                    } header: {
                        Text(String(localized: "cardMappings.targetAccount"))
                    }

                    Section {
                        ForEach(Array(keywords.indices), id: \.self) { index in
                            HStack {
                                TextField(String(localized: "cardMappings.keywordPrompt"), text: $keywords[index])
                                    .accessibilityIdentifier(index == 0 ? "cardMappings.keywordField" : "cardMappings.keywordField.\(index)")
                                    .autocorrectionDisabled()

                                if keywords.count > 1 {
                                    Button(role: .destructive) {
                                        keywords.remove(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(String(localized: "cardMappings.removeKeyword"))
                                    .accessibilityIdentifier("cardMappings.removeKeyword.\(index)")
                                }
                            }
                        }

                        Button {
                            keywords.append("")
                        } label: {
                            Label(String(localized: "cardMappings.addKeyword"), systemImage: "plus")
                        }
                        .accessibilityIdentifier("cardMappings.addKeywordButton")
                    } header: {
                        Text(String(localized: "cardMappings.keywordsSection"))
                    } footer: {
                        Text(String(localized: "cardMappings.footer"))
                    }
                }
                .navigationTitle(isEditing
                    ? String(localized: "Edit Mapping")
                    : String(localized: "cardMappings.addTitle"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { showingSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save")) {
                            saveMapping()
                            showingSheet = false
                        }
                        .disabled(cleanedKeywords.isEmpty || selectedAccountId.isEmpty)
                    }
                }
            }
        }
    }

    /// Keywords to remove when saving the sheet. Drops any original keyword
    /// that is no longer present in the updated set.
    nonisolated static func keywordsRemovedBySave(originalKeywords: [String], cleanedKeywords: [String]) -> [String] {
        let cleanedSet = Set(cleanedKeywords)
        return originalKeywords.filter { !cleanedSet.contains($0) }
    }

    /// Backwards-compatible single keyword removal helper.
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
        keywords = keyword.isEmpty ? [""] : [keyword]
        originalKeywords = []
        isEditing = false
        showingSheet = true
    }

    private func prepareAndShowEditSheet(accountId: String, keywords: [String]) {
        selectedAccountId = accountId
        self.keywords = keywords.isEmpty ? [""] : keywords
        originalKeywords = keywords
        isEditing = true
        showingSheet = true
    }

    private func deleteAccountMapping(at offsets: IndexSet) {
        let keysToDelete = offsets.flatMap { mappedAccounts[$0].keywords }
        Task {
            await budgetStore.deleteCardAccountMappings(keywords: keysToDelete)
        }
    }

    private func saveMapping() {
        let cleaned = cleanedKeywords
        guard !cleaned.isEmpty, !selectedAccountId.isEmpty else { return }
        let accountId = selectedAccountId
        let removed = Self.keywordsRemovedBySave(originalKeywords: originalKeywords, cleanedKeywords: cleaned)
        Task {
            await budgetStore.updateCardAccountMappings(accountId: accountId, keywords: cleaned, removingKeywords: removed)
        }
    }
}

/// A flow layout that wraps subviews to the next line when width is exceeded.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
            height = currentY + maxHeightInRow
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
    }
}

#Preview {
    NavigationStack {
        CardAccountMappingsView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
