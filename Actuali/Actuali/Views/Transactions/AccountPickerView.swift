import SwiftUI

/// Searchable account list pushed from the transaction form's account row.
/// Modeled after `CategoryPickerView` — pushed via `.navigationDestination`,
/// with a search bar pinned above the list. Reuses `AccountListBucket` to mirror
/// the Accounts tab layout (On Budget first, then Off Budget).
struct AccountPickerView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedAccountId: String
    let accounts: [Account]
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        List {
            bucketSection(String(localized: "On Budget"), onBudgetBuckets)
            bucketSection(String(localized: "Off Budget"), offBudgetBuckets)
        }
        .navigationTitle(String(localized: "Account"))
        .tint(.primary)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if onBudgetBuckets.isEmpty, offBudgetBuckets.isEmpty, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isSearchFocused = true
        }
    }

    @ViewBuilder
    private func bucketSection(_ title: String, _ buckets: [AccountListBucket]) -> some View {
        if !buckets.isEmpty {
            Section(title) {
                ForEach(buckets) { bucket in
                    if let group = bucket.group {
                        Text(group.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(bucket.accounts) { account in
                        accountRow(account)
                    }
                }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        Button {
            selectedAccountId = account.id
            dismiss()
        } label: {
            HStack {
                Text(account.name)
                    .foregroundStyle(.primary)
                Spacer()
                Text(budgetStore.displayBalance(account.balance))
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

    private var filteredAccounts: [Account] {
        AccountsListView.filterAccounts(accounts, groups: budgetStore.accountGroups, matching: searchText)
    }

    private var onBudgetBuckets: [AccountListBucket] {
        AccountListBucket.buckets(
            for: filteredAccounts.filter { !$0.offBudget },
            groups: budgetStore.accountGroups
        )
    }

    private var offBudgetBuckets: [AccountListBucket] {
        AccountListBucket.buckets(
            for: filteredAccounts.filter(\.offBudget),
            groups: budgetStore.accountGroups
        )
    }
}
