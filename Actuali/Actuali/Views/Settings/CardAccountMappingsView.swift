import SwiftUI

/// View for managing card last-4 digits / bank keyword -> account mappings.
struct CardAccountMappingsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @ObservedObject var pendingImportStore: PendingImportStore = .shared
    @State private var showingSheet = false
    @State private var keywords: [KeywordEntry] = [KeywordEntry()]
    @State private var keywordTexts: [UUID: String] = [:]
    @State private var originalKeywords: [String] = []
    @State private var selectedAccountId = ""
    @State private var isEditing = false

    private struct KeywordEntry: Identifiable {
        let id = UUID()
    }

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

    nonisolated static func groupByAccount(
        cardMappings: [String: String],
        accounts: [Account]
    ) -> [MappedAccount] {
        let accountsById = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var keywordsByAccount: [String: [String]] = [:]
        for (keyword, accountId) in cardMappings {
            keywordsByAccount[accountId, default: []].append(keyword)
        }
        return keywordsByAccount.map { accountId, keywords in
            MappedAccount(
                accountId: accountId,
                accountName: accountsById[accountId] ?? String(localized: "Unknown Account"),
                keywords: keywords.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            )
        }.sorted { $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending }
    }

    private var mappedAccounts: [MappedAccount] {
        Self.groupByAccount(cardMappings: budgetStore.cardAccountMappings, accounts: budgetStore.accounts)
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
        keywords.compactMap { keywordTexts[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var effectiveAccountId: String {
        if !selectedAccountId.isEmpty { return selectedAccountId }
        return PendingImportApprover.seedAccountId(
            cardHint: nil,
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings,
            defaultAccountId: budgetStore.defaultAccountId
        ) ?? budgetStore.accounts.first(where: { !$0.closed })?.id ?? ""
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
                            prepareAndShowEditSheet(accountId: item.accountId, existingKeywords: item.keywords)
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
                        Picker(
                            String(localized: "cardMappings.targetAccount"),
                            selection: Binding(
                                get: { effectiveAccountId },
                                set: { selectedAccountId = $0 }
                            )
                        ) {
                            ForEach(budgetStore.accounts.filter { !$0.closed || $0.id == effectiveAccountId }) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                        .accessibilityIdentifier("cardMappings.accountPicker")
                    } header: {
                        Text(String(localized: "cardMappings.targetAccount"))
                    }

                    Section {
                        ForEach(keywords) { entry in
                            let entryID = entry.id
                            let index = keywords.firstIndex(where: { $0.id == entryID }) ?? 0
                            HStack {
                                TextField(
                                    String(localized: "cardMappings.keywordPrompt"),
                                    text: Binding(
                                        get: { keywordTexts[entryID, default: ""] },
                                        set: { keywordTexts[entryID] = $0 }
                                    )
                                )
                                    .accessibilityIdentifier(index == 0 ? "cardMappings.keywordField" : "cardMappings.keywordField.\(index)")
                                    .autocorrectionDisabled()

                                if keywords.count > 1 {
                                    Button(role: .destructive) {
                                        keywords.removeAll { $0.id == entryID }
                                        keywordTexts.removeValue(forKey: entryID)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(String(localized: "cardMappings.removeKeyword"))
                                    .accessibilityIdentifier("cardMappings.removeKeyword.\(index)")
                                }
                            }
                            .id(entryID)
                        }

                        Button {
                            let entry = KeywordEntry()
                            keywords.append(entry)
                            keywordTexts[entry.id] = ""
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
                        .disabled(cleanedKeywords.isEmpty || effectiveAccountId.isEmpty)
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

    private func prepareAndShowAddSheet(keyword: String) {
        selectedAccountId = PendingImportApprover.seedAccountId(
            cardHint: keyword.isEmpty ? nil : keyword,
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings,
            defaultAccountId: budgetStore.defaultAccountId
        ) ?? ""
        let entry = KeywordEntry()
        keywords = [entry]
        keywordTexts = [entry.id: keyword]
        originalKeywords = []
        isEditing = false
        showingSheet = true
    }

    private func prepareAndShowEditSheet(accountId: String, existingKeywords: [String]) {
        selectedAccountId = accountId
        let entries = existingKeywords.isEmpty ? [KeywordEntry()] : existingKeywords.map { _ in KeywordEntry() }
        keywords = entries
        keywordTexts = Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), existingKeywords.isEmpty ? [""] : existingKeywords))
        originalKeywords = existingKeywords
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
        let accountId = effectiveAccountId
        guard !cleaned.isEmpty, !accountId.isEmpty else { return }
        let removed = Self.keywordsRemovedBySave(originalKeywords: originalKeywords, cleanedKeywords: cleaned)
        Task {
            await budgetStore.setCardAccountMappings(accountId: accountId, keywords: cleaned, removingKeywords: removed)
        }
    }
}

/// A flow layout that wraps subviews to the next line when width is exceeded.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.replacingUnspecifiedDimensions().width
        var usedWidth: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            currentX += size.width + spacing
            usedWidth = max(usedWidth, currentX - spacing)
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
        return CGSize(width: min(usedWidth, maxWidth), height: currentY + maxHeightInRow)
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
