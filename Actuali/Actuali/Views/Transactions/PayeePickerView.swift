import SwiftUI

struct PayeePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var budgetStore: BudgetStore

    @Binding var nearbyPayees: [NearbyPayee]
    let onSelect: (Payee) -> Void
    let onCommit: (String) -> Void
    let onDeleteNearby: (NearbyPayee) -> Void

    @State private var searchText: String
    @State private var suggestedPayees: [Payee] = []
    @State private var isSearchPresented = true

    init(
        payeeName: String,
        nearbyPayees: Binding<[NearbyPayee]>,
        onSelect: @escaping (Payee) -> Void,
        onCommit: @escaping (String) -> Void,
        onDeleteNearby: @escaping (NearbyPayee) -> Void
    ) {
        _nearbyPayees = nearbyPayees
        self.onSelect = onSelect
        self.onCommit = onCommit
        self.onDeleteNearby = onDeleteNearby
        _searchText = State(initialValue: payeeName)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredPayees: [Payee] {
        Self.filteredPayees(from: budgetStore.payees, searchText: trimmedSearchText)
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
        let usablePayees = allowedPayees(payees)

        guard !searchText.isEmpty else {
            return usablePayees
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name)
                        == .orderedAscending
                }
                .prefix(20)
                .map { $0 }
        }

        let lower = searchText.lowercased()

        return usablePayees
            .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.name.lowercased().hasPrefix(lower)
                let rhsPrefix = rhs.name.lowercased().hasPrefix(lower)

                if lhsPrefix != rhsPrefix {
                    return lhsPrefix
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
            .prefix(20)
            .map { $0 }
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

    private func payeeButton(_ payee: Payee) -> some View {
        Button {
            onSelect(payee)
        } label: {
            Label {
                Text(payee.name)
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
                                Text("Use \"\(trimmedSearchText)\"")
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
