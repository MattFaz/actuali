import SwiftUI

struct PayeePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var budgetStore: BudgetStore

    @Binding var nearbyPayees: [NearbyPayee]
    let transferFromAccountId: String?
    let onSelect: (Payee) -> Void
    let onCommit: (String) -> Void
    let onDeleteNearby: (NearbyPayee) -> Void

    @State private var searchText: String
    @State private var suggestedPayees: [Payee] = []
    @State private var isSearchPresented = true

    init(
        payeeName: String,
        nearbyPayees: Binding<[NearbyPayee]>,
        transferFromAccountId: String? = nil,
        onSelect: @escaping (Payee) -> Void,
        onCommit: @escaping (String) -> Void,
        onDeleteNearby: @escaping (NearbyPayee) -> Void
    ) {
        _nearbyPayees = nearbyPayees
        self.transferFromAccountId = transferFromAccountId
        self.onSelect = onSelect
        self.onCommit = onCommit
        self.onDeleteNearby = onDeleteNearby
        _searchText = State(initialValue: payeeName)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredPayees: [Payee] {
        Self.filteredPayees(
            from: budgetStore.payees,
            accounts: budgetStore.accounts,
            transferFromAccountId: transferFromAccountId,
            searchText: trimmedSearchText
        )
    }

    nonisolated static func allowedPayees(_ payees: [Payee]) -> [Payee] {
        payees.filter { payee in
            !payee.tombstone && payee.transferAccountId == nil
        }
    }

    nonisolated static func filteredPayees(
        from payees: [Payee],
        searchText: String
    ) -> [Payee] {
        filteredPayees(
            from: payees, accounts: [], transferFromAccountId: nil,
            searchText: searchText
        )
    }

    nonisolated static func filteredPayees(
        from payees: [Payee],
        accounts: [Account],
        transferFromAccountId: String?,
        searchText: String
    ) -> [Payee] {
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let openAccountIds = Set(accounts.filter { !$0.closed }.map(\.id))
        let usablePayees = payees.filter { payee in
            guard !payee.tombstone else { return false }
            guard let transferAccountId = payee.transferAccountId else { return true }
            return transferFromAccountId != nil
                && transferAccountId != transferFromAccountId
                && openAccountIds.contains(transferAccountId)
        }
        func name(_ payee: Payee) -> String {
            displayName(for: payee, accountNames: accountNames)
        }

        guard !searchText.isEmpty else {
            let sorted = usablePayees.sorted {
                    name($0).localizedCaseInsensitiveCompare(name($1))
                        == .orderedAscending
                }
            guard transferFromAccountId != nil else {
                return Array(sorted.prefix(20))
            }
            return Array(sorted.filter { $0.transferAccountId == nil }.prefix(20))
                + sorted.filter { $0.transferAccountId != nil }
        }

        let lower = searchText.lowercased()

        return usablePayees
            .filter { name($0).localizedCaseInsensitiveContains(searchText) }
            .sorted { lhs, rhs in
                let lhsName = name(lhs)
                let rhsName = name(rhs)
                let lhsPrefix = lhsName.lowercased().hasPrefix(lower)
                let rhsPrefix = rhsName.lowercased().hasPrefix(lower)

                if lhsPrefix != rhsPrefix {
                    return lhsPrefix
                }

                return lhsName.localizedCaseInsensitiveCompare(rhsName)
                    == .orderedAscending
            }
            .prefix(20)
            .map { $0 }
    }

    nonisolated static func displayName(
        for payee: Payee,
        accounts: [Account]
    ) -> String {
        displayName(
            for: payee,
            accountNames: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        )
    }

    private nonisolated static func displayName(
        for payee: Payee,
        accountNames: [String: String]
    ) -> String {
        guard let accountId = payee.transferAccountId,
              let accountName = accountNames[accountId] else { return payee.name }
        return "\(String(localized: "Transfer")): \(accountName)"
    }

    private var nonSuggestedPayees: [Payee] {
        filteredPayees.filter { payee in
            !suggestedPayees.contains { suggestedPayee in
                suggestedPayee.id == payee.id
            }
        }
    }

    private var canCommitCustomPayee: Bool {
        Self.canCommitCustomPayee(
            searchText: trimmedSearchText,
            payees: budgetStore.payees
        )
    }

    nonisolated static func canCommitCustomPayee(
        searchText: String,
        payees: [Payee]
    ) -> Bool {
        guard !searchText.isEmpty else {
            return false
        }

        return !payees.contains { payee in
            !payee.tombstone &&
                payee.transferAccountId == nil &&
                payee.name.caseInsensitiveCompare(searchText) == .orderedSame
        }
    }

    nonisolated static func committedPayeeId(
        currentName: String,
        currentId: String?,
        committedName: String
    ) -> String? {
        currentName == committedName ? currentId : nil
    }

    private func payeeButton(_ payee: Payee) -> some View {
        Button {
            onSelect(payee)
        } label: {
            Label {
                Text(Self.displayName(for: payee, accounts: budgetStore.accounts))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if trimmedSearchText.isEmpty {
                    if !nearbyPayees.isEmpty {
                        Section("Nearby") {
                            ForEach(nearbyPayees.prefix(5)) { nearby in
                                Button {
                                    onSelect(nearby.payee)
                                } label: {
                                    HStack {
                                        Image(systemName: "location.fill")
                                            .foregroundStyle(.secondary)
                                            .font(.footnote)
                                        Text(nearby.payee.name)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(LocationUtils.formatDistance(meters: nearby.distanceMeters))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        onDeleteNearby(nearby)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    if !suggestedPayees.isEmpty {
                        Section("Suggested Payees") {
                            ForEach(suggestedPayees.prefix(5)) { payee in
                                payeeButton(payee)
                            }
                        }
                    }

                    if !nonSuggestedPayees.isEmpty {
                        Section("Payees") {
                            ForEach(nonSuggestedPayees) { payee in
                                payeeButton(payee)
                            }
                        }
                    }
                } else if !filteredPayees.isEmpty {
                    Section("Suggestions") {
                        ForEach(filteredPayees) { payee in
                            payeeButton(payee)
                        }
                    }
                }

                if canCommitCustomPayee {
                    Section {
                        Button {
                            onCommit(trimmedSearchText)
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.tint)
                                Text(String(format: String(localized: "Use \"%@\""), trimmedSearchText))
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Payee")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search payees"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onCommit(trimmedSearchText)
                    }
                }
            }
            .task {
                suggestedPayees = Self.allowedPayees(
                    await budgetStore.fetchCommonPayees()
                )
            }
        }
    }
}
