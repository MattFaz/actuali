import SwiftUI

/// Section representation for account pickers (both the inline dropdown menu
/// and the dedicated searchable picker).
struct AccountPickerSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let accounts: [Account]
}

/// Searchable account list, companion to the transaction form's account dropdown.
/// Modeled after `CategoryPickerView` — pushed via `.navigationDestination`,
/// with a search bar pinned above the list.
struct AccountPickerView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedAccountId: String
    let accounts: [Account]
    var autofocusSearch: Bool = true
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        List {
            ForEach(filteredSections) { section in
                Section(section.title) {
                    ForEach(section.accounts) { account in
                        Button {
                            selectedAccountId = account.id
                            dismiss()
                        } label: {
                            HStack {
                                Text(account.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(budgetStore.formatCurrency(account.balance))
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                                if selectedAccountId == account.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier("accountPicker.account.\(account.id)")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Account"))
        .tint(.primary)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if filteredSections.isEmpty, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PickerSearchBar(text: $searchText, clearButtonIdentifier: "accountPicker.clearSearch") {
                TextField(String(localized: "Search Accounts"), text: $searchText)
                    .focused($isSearchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { isSearchFocused = false }
                    .accessibilityIdentifier("accountPicker.searchField")
            }
        }
        // The navigation transition must settle before UIKit can claim the
        // first responder for this destination.
        .task {
            guard autofocusSearch else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isSearchFocused = true
        }
    }

    private var filteredSections: [AccountPickerSection] {
        let grouped = Self.groupAccounts(accounts, groups: budgetStore.accountGroups)
        return Self.filterSections(grouped, matching: searchText)
    }

    /// Group open accounts into display sections: custom account groups first,
    /// followed by ungrouped on-budget and off-budget sections. When no custom
    /// groups exist, accounts fall into "On Budget" and "Off Budget".
    nonisolated static func groupAccounts(
        _ accounts: [Account],
        groups: [AccountGroup]
    ) -> [AccountPickerSection] {
        let activeGroups = groups.filter { !$0.tombstone }.sorted { $0.sortOrder < $1.sortOrder }
        let groupIds = Set(activeGroups.map(\.id))

        if activeGroups.isEmpty {
            var sections: [AccountPickerSection] = []
            let onBudget = accounts.filter { !$0.offBudget }
            if !onBudget.isEmpty {
                sections.append(AccountPickerSection(
                    id: "on-budget",
                    title: String(localized: "On Budget"),
                    accounts: onBudget
                ))
            }
            let offBudget = accounts.filter(\.offBudget)
            if !offBudget.isEmpty {
                sections.append(AccountPickerSection(
                    id: "off-budget",
                    title: String(localized: "Off Budget"),
                    accounts: offBudget
                ))
            }
            return sections
        }

        var sections: [AccountPickerSection] = []

        // Custom account groups in their sort order
        for group in activeGroups {
            let members = accounts.filter { $0.groupId == group.id }
            if !members.isEmpty {
                sections.append(AccountPickerSection(
                    id: group.id,
                    title: group.name,
                    accounts: members
                ))
            }
        }

        // Ungrouped on-budget accounts
        let ungroupedOnBudget = accounts.filter { !$0.offBudget && ($0.groupId.map(groupIds.contains) != true) }
        if !ungroupedOnBudget.isEmpty {
            sections.append(AccountPickerSection(
                id: "on-budget",
                title: String(localized: "On Budget"),
                accounts: ungroupedOnBudget
            ))
        }

        // Ungrouped off-budget accounts
        let ungroupedOffBudget = accounts.filter { $0.offBudget && ($0.groupId.map(groupIds.contains) != true) }
        if !ungroupedOffBudget.isEmpty {
            sections.append(AccountPickerSection(
                id: "off-budget",
                title: String(localized: "Off Budget"),
                accounts: ungroupedOffBudget
            ))
        }

        return sections
    }

    /// Filter sections and their contained accounts by a case-insensitive query.
    /// Matches against either the account name or the section group title.
    nonisolated static func filterSections(
        _ sections: [AccountPickerSection],
        matching query: String
    ) -> [AccountPickerSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }

        return sections.compactMap { section in
            let matchesGroup = section.title.localizedCaseInsensitiveContains(trimmed)
            let matchingAccounts = section.accounts.filter { account in
                matchesGroup || account.name.localizedCaseInsensitiveContains(trimmed)
            }
            guard !matchingAccounts.isEmpty else { return nil }
            return AccountPickerSection(
                id: section.id,
                title: section.title,
                accounts: matchingAccounts
            )
        }
    }
}
