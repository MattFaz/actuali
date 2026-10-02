import SwiftUI

struct TransactionsListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var pager: TransactionPager?
    @State private var searchText = ""
    @State private var editingTransaction: Transaction?
    @State private var isSelecting = false
    @State private var selectedTransactionIds: Set<String> = []

    private var searchQuery: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Wraps `isSelecting` so every path that leaves selection mode — the
    /// toolbar's Done button, or a row's long-press-to-exit — clears the
    /// selected set the same way. Passed to rows instead of `$isSelecting`
    /// directly so a long press while already selecting can safely toggle
    /// off without leaving stale selected IDs behind.
    private var selectionModeBinding: Binding<Bool> {
        Binding(
            get: { isSelecting },
            set: { newValue in
                withAnimation {
                    isSelecting = newValue
                    if !newValue {
                        selectedTransactionIds.removeAll()
                    }
                }
            }
        )
    }

    /// The pager is created on first use rather than in init because its
    /// fetch closure needs the environment store, which isn't available
    /// until body/task time.
    private func currentPager() -> TransactionPager {
        if let pager {
            return pager
        }
        let store = budgetStore
        let created = TransactionPager { offset, limit, search in
            await store.fetchTransactions(
                limit: limit, offset: offset, search: search,
                statusFilter: store.transactionStatusFilter
            )
        }
        pager = created
        return created
    }

    private func reload() async {
        await currentPager().loadFirstPage(search: searchQuery)
    }

    var body: some View {
        Group {
            if let pager, pager.transactions.isEmpty, !budgetStore.isLoading {
                if searchQuery != nil {
                    ContentUnavailableView.search(text: searchText)
                } else if budgetStore.transactionStatusFilter != .all {
                    ContentUnavailableView {
                        Label("No Matching Transactions", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Try another status filter.")
                    } actions: {
                        Button("Show All Transactions") {
                            budgetStore.transactionStatusFilter = .all
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Transactions",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Transactions will appear here once you load a budget")
                    )
                }
            } else if let pager {
                List {
                    if budgetStore.transactionDisplayMode == .groupedByDate {
                        let groups = pager.transactions.groupedByDate()
                        ForEach(groups) { group in
                            Section(group.title) {
                                ForEach(group.transactions) { transaction in
                                    TransactionListRow(
                                        transaction: transaction,
                                        showDate: false,
                                        isSelectionMode: selectionModeBinding,
                                        isSelected: selectedTransactionIds.contains(transaction.id),
                                        editing: $editingTransaction,
                                        onToggleSelect: {
                                            selectedTransactionIds.formSymmetricDifference([transaction.id])
                                        }
                                    )
                                }
                                // The sentinel rides in the last date section
                                // so grouped mode doesn't grow a headerless
                                // section (and its gap) of its own.
                                if pager.hasMore, group.id == groups.last?.id {
                                    TransactionPagingSentinel(pager: pager)
                                }
                            }
                        }
                    } else {
                        ForEach(pager.transactions) { transaction in
                            TransactionListRow(
                                transaction: transaction,
                                isSelectionMode: selectionModeBinding,
                                isSelected: selectedTransactionIds.contains(transaction.id),
                                editing: $editingTransaction,
                                onToggleSelect: {
                                    selectedTransactionIds.formSymmetricDifference([transaction.id])
                                }
                            )
                        }
                        if pager.hasMore {
                            TransactionPagingSentinel(pager: pager)
                        }
                    }
                }
            }
        }
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .readableWidth()
        .navigationTitle("All Accounts")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isSelecting ? "Done" : "Select") {
                    selectionModeBinding.wrappedValue.toggle()
                }
                .accessibilityIdentifier("transactions.selectionMode")
            }
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: $budgetStore.showTransactionStatusFilters) {
                    Label("Status Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                TransactionGroupingToggle()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting, let pager {
                TransactionBulkActionBar(
                    transactions: pager.transactions,
                    selectedIds: $selectedTransactionIds,
                    isSelecting: $isSelecting
                )
            }
        }
        .toolbar(isSelecting ? .hidden : .visible, for: .tabBar)
        .task(id: searchText) {
            // Debounce keystrokes; the initial (empty) load runs immediately.
            if searchQuery != nil {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled {
                    return
                }
            }
            await reload()
        }
        .onChange(of: budgetStore.dataVersion) {
            // The store republished its data — refresh the cached page. This
            // is the single reload path for every mutation (row toggles,
            // deletes, sheet edits, sync, scheduled posts), so those sites
            // carry no reload calls of their own. Concurrent reloads are
            // safe: the pager's generation counter keeps the newest.
            Task { await reload() }
        }
        .onChange(of: budgetStore.transactionStatusFilter) {
            // The pager's fetch closure reads the chip, so a reload is all a
            // chip tap needs.
            Task { await reload() }
        }
        .refreshable {
            await budgetStore.sync()
            await reload()
        }
        .sheet(item: $editingTransaction) { transaction in
            AddTransactionView(editing: transaction)
                .environmentObject(budgetStore)
        }
        .overlay {
            if budgetStore.isLoading {
                ProgressView()
            }
        }
    }
}

/// Tappable `TransactionRow` with the standard edit/delete swipe actions,
/// shared by the all-accounts and account-detail lists. The category and
/// uncategorized lists build their own rows: they suppress tap and swipe on
/// split children and reload after every mutation.
struct TransactionListRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    let transaction: Transaction
    var showAccount: Bool = true
    var showDate: Bool = true
    /// A binding, so a long press on the row opens selection mode for every
    /// caller with no extra callback.
    @Binding var isSelectionMode: Bool
    var isSelected: Bool = false
    @Binding var editing: Transaction?
    var onToggleSelect: (() -> Void)?

    /// A counter, not a Bool: `.sensoryFeedback` needs a value that changes
    /// on every long press, and the toolbar Select button must not fire it.
    @State private var longPressCount = 0

    var body: some View {
        Button {
            if isSelectionMode {
                onToggleSelect?()
            } else {
                editing = transaction
            }
        } label: {
            TransactionRow(
                transaction: transaction,
                showAccount: showAccount,
                showDate: showDate,
                isSelectionMode: isSelectionMode,
                isSelected: isSelected,
                onToggleCleared: {
                    Task { await budgetStore.toggleCleared(transaction) }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transactionRow.\(transaction.id)")
        // `highPriorityGesture`, not `simultaneousGesture`: this row's label
        // contains its own nested Button (the cleared-status dot), and a
        // merely-simultaneous long press doesn't stop that button's tap from
        // also firing on release — a held cleared dot would toggle cleared
        // status (or open its unlock confirmation) as a side effect of
        // entering selection mode. High priority wins the touch outright
        // once 0.5s is reached, so neither the nested button nor this row's
        // own Button action fires; a tap shorter than that still passes
        // through untouched. Because the row's own release action no longer
        // fires either, this handler selects the row directly.
        //
        // A long press while already in selection mode exits it instead:
        // `isSelectionMode` is bound to the shared selection-mode binding,
        // so setting it false here clears the whole selected set the same
        // way the toolbar's Done button does.
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                longPressCount += 1
                withAnimation {
                    if isSelectionMode {
                        isSelectionMode = false
                    } else {
                        isSelectionMode = true
                        onToggleSelect?()
                    }
                }
            }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: longPressCount)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectionMode {
                Button(role: .destructive) {
                    Task { await budgetStore.deleteTransaction(transaction) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    Task { await budgetStore.duplicateTransaction(transaction) }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .tint(.blue)
                Button {
                    editing = transaction
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.yellow)
            }
        }
    }
}

/// Sentinel row: appearing near the bottom of the list pulls in the next page.
struct TransactionPagingSentinel: View {
    let pager: TransactionPager

    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .task { await pager.loadNextPage() }
    }
}

/// Flat-vs-grouped switch for the transaction list toolbars.
///
/// A Toggle rather than the Picker Settings uses: `.secondaryAction` silently
/// drops a Picker when it collapses into the `…` menu (inline or not), while a
/// Toggle renders — same as the "Status Filters" switch beside it.
/// The mode only has two cases, so nothing is lost.
struct TransactionGroupingToggle: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    private var isGrouped: Bool {
        budgetStore.transactionDisplayMode == .groupedByDate
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isGrouped },
            set: { budgetStore.transactionDisplayMode = $0 ? .groupedByDate : .flat }
        )) {
            Label(
                "Group by Date",
                systemImage: isGrouped ? "calendar.badge.checkmark" : "calendar"
            )
        }
    }
}

struct TransactionRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let transaction: Transaction
    var showAccount: Bool = true
    var showDate: Bool = true
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    /// Tap action for the cleared-status dot. Nil leaves the dot inert
    /// (split-child rows, contexts without a reload path). Reconciled rows
    /// confirm before invoking, since the store unlocks them instead.
    var onToggleCleared: (() -> Void)?

    @State private var confirmingUnlock = false

    var accountName: String {
        budgetStore.accounts.first { $0.id == transaction.accountId }?.name
            ?? String(localized: TransactionsListLocalization.unknownAccount, locale: locale)
    }

    private var isInOffBudgetAccount: Bool {
        budgetStore.offBudgetAccountIds.contains(transaction.accountId)
    }

    private var isTransfer: Bool {
        transaction.transferId != nil || transaction.transferAcct != nil
    }

    /// Split parents may resolve no payee (mixed child payees) — label them
    /// "Split" like the desktop app, not "Unknown". Off-budget rows say
    /// "No payee": they're commonly payee-less (balance adjustments) and
    /// "Unknown" read as a bug (GH #123).
    nonisolated static func payeeLabel(
        payeeName: String?,
        isParent: Bool,
        isInOffBudgetAccount: Bool,
        locale: Locale
    ) -> String {
        payeeName ?? (isParent
            ? String(localized: TransactionsListLocalization.split, locale: locale)
            : (isInOffBudgetAccount
                ? String(localized: TransactionsListLocalization.noPayee, locale: locale)
                : String(localized: TransactionsListLocalization.unknown, locale: locale)))
    }

    /// Caption under the payee. Off-budget accounts aren't categorized at all
    /// ("Off budget", GH #123); split parents say "Split" (as the PWA does)
    /// followed by their children's breakdown, so the split reads at a glance
    /// without opening it (GH #552); transfers that can't take a category
    /// show "Transfer" instead of nagging "Uncategorized" (GH #104).
    nonisolated static func categoryLabel(
        categoryName: String?,
        isParent: Bool,
        splitBreakdown: String?,
        isInOffBudgetAccount: Bool,
        isTransfer: Bool,
        needsCategory: Bool,
        locale: Locale
    ) -> String {
        if isInOffBudgetAccount {
            return String(localized: TransactionsListLocalization.offBudget, locale: locale)
        }
        if isParent {
            let split = String(localized: TransactionsListLocalization.split, locale: locale)
            return splitBreakdown.map { "\(split)・\($0)" } ?? split
        }
        if categoryName == nil, isTransfer, !needsCategory {
            return String(localized: TransactionsListLocalization.transfer, locale: locale)
        }
        return categoryName
            ?? String(localized: TransactionsListLocalization.uncategorized, locale: locale)
    }

    /// "Food $6.00, Refund +$4.00": outflows unsigned, inflows keep a "+" so a
    /// credit line inside a spend split stays distinguishable (GH #216).
    private var splitBreakdown: String? {
        guard let portions = transaction.splitPortions, !portions.isEmpty else { return nil }
        return portions.map { portion in
            let name = portion.categoryName
                ?? String(localized: TransactionsListLocalization.uncategorized, locale: locale)
            return "\(name) \(budgetStore.displaySpentCaption(portion.amount))"
        }.joined(separator: ", ")
    }

    private var categoryLabel: String {
        Self.categoryLabel(
            categoryName: transaction.categoryName,
            isParent: transaction.isParent,
            splitBreakdown: splitBreakdown,
            isInOffBudgetAccount: isInOffBudgetAccount,
            isTransfer: isTransfer,
            needsCategory: transaction.needsCategory(
                offBudgetAccountIds: budgetStore.offBudgetAccountIds
            ),
            locale: locale
        )
    }

    /// The note, wrapping over as many lines as it needs, with each `#tag`
    /// drawn as a colored chip in place so the tags read as part of the note.
    private func noteLine(_ notes: String) -> some View {
        WrappingHStack(spacing: 4, lineSpacing: 2) {
            ForEach(Array(TagFilter.noteSegments(notes).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { _, word in
                        Text(word)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .tag(let rawTag):
                    tagChip(rawTag)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notes)
    }

    private func tagChip(_ rawTag: String) -> some View {
        let match = budgetStore.tagsByName[Tag.normalizeTagName(rawTag).lowercased()]
        let tagColor = match?.swiftUIColor ?? .secondary
        return Text(rawTag)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tagColor.opacity(0.15), in: Capsule())
            .foregroundStyle(tagColor)
    }

    var body: some View {
        HStack(spacing: 10) {
            if isSelectionMode {
                // No button needed: the row itself toggles selection. The
                // cleared dot stays in view — the bulk bar acts on it.
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    ClearedIndicator(cleared: transaction.cleared, reconciled: transaction.reconciled)
                }
                .frame(width: 48, height: 28)
                .accessibilityLabel(TransactionsListLocalization.selectionLabel(
                    isSelected: isSelected,
                    locale: locale
                ))
            } else if let onToggleCleared {
                Button {
                    if transaction.reconciled {
                        confirmingUnlock = true
                    } else {
                        onToggleCleared()
                    }
                } label: {
                    ClearedIndicator(cleared: transaction.cleared, reconciled: transaction.reconciled)
                        // Grow the tap target beyond the 14 pt glyph without
                        // changing the row's layout.
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("transaction.status.\(transaction.id)")
                .accessibilityHint(String(localized: TransactionsListLocalization.togglesCleared, locale: locale))
                .confirmationDialog(
                    "This transaction is reconciled. Unlock it to make changes?",
                    isPresented: $confirmingUnlock,
                    titleVisibility: .visible
                ) {
                    Button("Unlock") { onToggleCleared() }
                }
            } else {
                // Same footprint as the tappable variant so mixed lists
                // (split children under parents) keep their columns aligned.
                ClearedIndicator(cleared: transaction.cleared, reconciled: transaction.reconciled)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.payeeLabel(
                    payeeName: transaction.payeeName,
                    isParent: transaction.isParent,
                    isInOffBudgetAccount: isInOffBudgetAccount,
                    locale: locale
                ))
                .font(.body)
                HStack(spacing: 4) {
                    if transaction.isParent {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(categoryLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = transaction.notes, !notes.isEmpty {
                    noteLine(notes)
                }
            }
            // Take all the width the amount column leaves. A trailing Spacer
            // would claim half of it, wrapping notes well before the amount.
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(budgetStore.displayBalance(transaction.amount))
                    .foregroundColor(transaction.isOutflow ? .primary : .green)
                if showAccount {
                    Text(accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .trailing)
                }
                if let runningBalance = transaction.runningBalance {
                    Text(budgetStore.displayBalance(runningBalance))
                        .foregroundStyle(balanceColor(for: runningBalance))
                        .font(.caption)
                }
                if showDate {
                    Text(transaction.dateFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .onChange(of: isSelectionMode) { _, active in
            // The row's long-press gesture spans the cleared-status button
            // too, so a hold on the dot can flip this row into selection
            // mode while that button's own action is still landing. Selection
            // mode removes the button and its confirmationDialog, so a
            // pending confirmingUnlock would otherwise surface later with no
            // toggle behind it.
            if active {
                confirmingUnlock = false
            }
        }
    }
}

/// Lays its children out left to right and wraps to a new line when the row
/// is full, centering each line's children vertically. Used for a note whose
/// words and tag chips flow together.
private struct WrappingHStack: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for width: CGFloat, _ subviews: Subviews) -> [Line] {
        var lines = [Line()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = lines.last, !last.indices.isEmpty, last.width + spacing + size.width > width {
                lines.append(Line())
            }
            let gap = lines[lines.count - 1].indices.isEmpty ? 0 : spacing
            lines[lines.count - 1].indices.append(index)
            lines[lines.count - 1].width += gap + size.width
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let lines = lines(for: proposal.width ?? .infinity, subviews)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for line in lines(for: bounds.width, subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}

struct ClearedIndicator: View {
    @Environment(\.locale) private var locale
    let cleared: Bool
    let reconciled: Bool

    var body: some View {
        Group {
            if reconciled {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.green)
                    .imageScale(.large)
            } else if cleared {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14))
        .accessibilityLabel(TransactionsListLocalization.statusLabel(
            cleared: cleared,
            reconciled: reconciled,
            locale: locale
        ))
    }
}

enum TransactionsListLocalization {
    static let cleared: String.LocalizationValue = "Cleared"
    static let noPayee: String.LocalizationValue = "No payee"
    static let notSelected: String.LocalizationValue = "Not selected"
    static let offBudget: String.LocalizationValue = "Off budget"
    static let reconciled: String.LocalizationValue = "Reconciled"
    static let selected: String.LocalizationValue = "Selected"
    static let split: String.LocalizationValue = "Split"
    static let togglesCleared: String.LocalizationValue = "Toggles cleared status"
    static let transfer: String.LocalizationValue = "Transfer"
    static let uncleared: String.LocalizationValue = "Uncleared"
    static let uncategorized: String.LocalizationValue = "Uncategorized"
    static let unknown: String.LocalizationValue = "Unknown"
    static let unknownAccount: String.LocalizationValue = "Unknown Account"

    static func text(
        _ key: String,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        ReportStrings.text(key, locale: locale, bundle: bundle)
    }

    static func statusLabel(
        cleared: Bool,
        reconciled: Bool,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        text(reconciled ? reconciledKey : (cleared ? clearedKey : unclearedKey),
             locale: locale, bundle: bundle)
    }

    static func selectionLabel(
        isSelected: Bool,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        text(isSelected ? selectedKey : notSelectedKey, locale: locale, bundle: bundle)
    }

    private static let clearedKey = "Cleared"
    private static let reconciledKey = "Reconciled"
    private static let unclearedKey = "Uncleared"
    private static let selectedKey = "Selected"
    private static let notSelectedKey = "Not selected"
}

#Preview {
    NavigationStack {
        TransactionsListView()
    }
    .environmentObject(BudgetStore.previewInstance())
}
