// Actuali/Actuali/Views/Transactions/AddTransactionView.swift

import SwiftUI

struct AddTransactionView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    private let editing: Transaction?

    @State private var selectedAccountId: String
    @State private var amount: String
    @State private var txType: TransactionType
    @State private var payeeName: String
    @State private var transferToAccountId: String?
    @State private var selectedCategoryId: String?
    @State private var notes: String
    @State private var date: Date
    @State private var cleared: Bool

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var userPickedCategory = false
    @State private var nearbyPayees: [NearbyPayee] = []
    @State private var saveLocation = true
    @State private var splitLines: [BudgetStore.SplitLineForm] = []
    /// True while the edit form's "Remove Split" is toggled on an existing
    /// split parent: the lines are kept in memory (so tapping "Split into
    /// multiple categories" undoes the toggle instantly) but the form shows
    /// the category picker and saves as a single transaction.
    @State private var unsplitRequested = false

    @FocusState private var payeeFocused: Bool

    /// Initializer for the "Add" flow. The optional prefill parameters carry
    /// whatever an automation passed along — a failed Wallet log or the Add
    /// Transaction with Review intent (see TransactionPrefill).
    init(
        accountId: String,
        payee: String = "",
        amountCents: Int? = nil,
        date: Date = Date(),
        notes: String = "",
        categoryId: String? = nil,
        isIncome: Bool = false,
        cleared: Bool = false
    ) {
        self.editing = nil
        _selectedAccountId = State(initialValue: accountId)
        _amount = State(initialValue: amountCents.map { String(format: "%.2f", Double(abs($0)) / 100.0) } ?? "")
        _txType = State(initialValue: isIncome ? .income : .expense)
        _payeeName = State(initialValue: payee)
        _transferToAccountId = State(initialValue: nil)
        _selectedCategoryId = State(initialValue: categoryId)
        _notes = State(initialValue: notes)
        _date = State(initialValue: date)
        _cleared = State(initialValue: cleared)
        // A prefilled category is the automation's explicit choice — don't
        // let the payee-history suggestion overwrite it.
        _userPickedCategory = State(initialValue: categoryId != nil)
    }

    /// Initializer for the "Edit" flow. Transfer legs load as transfers —
    /// From/To derive from the leg's sign (the opened row can be either side)
    /// with the partner account read off the transfer payee (GH #104).
    init(editing: Transaction) {
        self.editing = editing

        let cents = abs(editing.amount)
        let dollars = Double(cents) / 100.0
        _amount = State(initialValue: String(format: "%.2f", dollars))
        if editing.transferId != nil {
            _txType = State(initialValue: .transfer)
            if editing.amount < 0 {
                _selectedAccountId = State(initialValue: editing.accountId)
                _transferToAccountId = State(initialValue: editing.transferAcct)
            } else {
                // Partner unknown (transfer payee missing): fall back to the
                // leg's own account as From and let the user pick To.
                _selectedAccountId = State(initialValue: editing.transferAcct ?? editing.accountId)
                _transferToAccountId = State(initialValue:
                    editing.transferAcct == nil ? nil : editing.accountId)
            }
        } else {
            _txType = State(initialValue: editing.amount < 0 ? .expense : .income)
            _selectedAccountId = State(initialValue: editing.accountId)
            _transferToAccountId = State(initialValue: nil)
        }
        _payeeName = State(initialValue: editing.payeeName ?? "")
        _selectedCategoryId = State(initialValue: editing.categoryId)
        _notes = State(initialValue: editing.notes ?? "")
        _date = State(initialValue: Transaction.date(fromYYYYMMDD: editing.date))
        _cleared = State(initialValue: editing.cleared)
    }

    private var isEditing: Bool { editing != nil }
    private var isTransfer: Bool { txType == .transfer }
    private var isEditingSplitParent: Bool { editing?.isParent == true }
    private var isEditingTransfer: Bool { editing?.transferId != nil }

    /// Whether the edit form may offer turning this transaction into a
    /// transfer (GH #259). Split parents and children are excluded — the
    /// store refuses them, since a parent's amount is its children's and a
    /// child has no row of its own to pair.
    private var canConvertToTransfer: Bool {
        guard let editing else { return false }
        return editing.transferId == nil && !editing.isParent && editing.parentId == nil
    }
    private var isConvertingToTransfer: Bool { isTransfer && canConvertToTransfer }

    /// A transfer leg takes a category only when it sits in an on-budget
    /// account and the other side is off-budget — money leaving the budget
    /// still needs one (Actual's rule). Tracks the live picker selections so
    /// re-targeting the accounts shows/hides the row immediately.
    private var editedTransferLegIsCategorizable: Bool {
        guard let editing, isTransfer else { return false }
        // The edited row's own account is the one in the account picker,
        // except on an existing transfer opened from its receiving leg —
        // there the form shows the pair as From/To and the opened row is To.
        let openedOnDestinationLeg = editing.transferId != nil && editing.amount >= 0
        let legAccountId = openedOnDestinationLeg ? transferToAccountId : selectedAccountId
        let otherAccountId = openedOnDestinationLeg ? selectedAccountId : transferToAccountId
        guard let leg = budgetStore.accounts.first(where: { $0.id == legAccountId }),
              let other = budgetStore.accounts.first(where: { $0.id == otherAccountId }) else {
            return false
        }
        return !leg.offBudget && other.offBudget
    }
    private var isSplitting: Bool { !splitLines.isEmpty && !unsplitRequested }

    /// Whether the form can offer the split option: a plain transaction in
    /// either flow, or an existing parent mid-"Remove Split" (as an undo).
    /// Transfers are excluded — they pair two accounts through `transferId`
    /// and splitting would orphan the partner leg (the store refuses it), so
    /// the button stays hidden rather than failing on save.
    private var canSplitIntoCategories: Bool {
        editing?.transferId == nil && (!isEditingSplitParent || unsplitRequested)
    }

    /// Cents still unassigned across the split lines, nil while the total
    /// doesn't parse yet. Blank lines count as zero so the remainder stays
    /// visible while the user is still filling lines in.
    private var splitRemainingCents: Int? {
        // Opposite-direction lines hand their amount back to the remainder
        // instead of consuming it (GH #216).
        SplitEntryMath.remainingCents(total: amount, lineAmounts: splitLines.map { line in
            line.isOpposite && !line.amount.isEmpty ? "-\(line.amount)" : line.amount
        })
    }

    private var hasBlankSplitLine: Bool {
        splitLines.contains { $0.amount.isEmpty }
    }

    /// Open accounts ordered to match the webapp's AccountAutocomplete:
    /// on-budget first, then off-budget, each group by sort_order.
    private var orderedOpenAccounts: [Account] {
        budgetStore.accounts
            .filter { !$0.closed }
            .sorted { lhs, rhs in
                if lhs.offBudget != rhs.offBudget { return !lhs.offBudget }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

    /// Converting keeps the edited row in its own account and on its own side
    /// of the transfer, so the form asks for one account — the other one —
    /// instead of the From/To pair a new transfer needs.
    private var accountPickerLabel: String {
        isTransfer && !isConvertingToTransfer ? "From" : "Account"
    }

    private var transferPartnerLabel: String {
        guard isConvertingToTransfer else { return "To" }
        return (editing?.amount ?? 0) < 0 ? "Transfer to" : "Transfer from"
    }

    private var transferEligibleAccounts: [Account] {
        orderedOpenAccounts.filter { $0.id != selectedAccountId }
    }

    private func matchingPayee(for name: String) -> Payee? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return budgetStore.payees.first { payee in
            !payee.tombstone &&
                payee.transferAccountId == nil &&
                payee.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    private func applyCategoryFromHistory(payeeId: String) {
        guard !userPickedCategory else { return }
        guard let db = budgetStore.databaseForLogger else { return }
        Task { @MainActor in
            guard let cat = try? await db.mostRecentCategoryId(forPayeeId: payeeId) else { return }
            // Re-check after the await: the user may have picked a category
            // while the lookup was in flight — don't clobber their choice.
            guard !userPickedCategory else { return }
            selectedCategoryId = cat
        }
    }

    /// Load nearby payees when the payee field gains focus. Requests
    /// permission on first use; every failure path degrades to "no
    /// suggestions" silently.
    private func loadNearbyPayees() {
        guard !isEditing else { return }
        Task { @MainActor in
            let provider = BudgetStore.locationProvider
            var status = await provider.authorizationStatus()
            if status == .notDetermined {
                status = await provider.requestPermission()
            }
            guard status == .granted,
                  let position = try? await provider.currentPosition() else {
                nearbyPayees = []
                return
            }
            nearbyPayees = await budgetStore.fetchNearbyPayees(
                latitude: position.latitude, longitude: position.longitude)
        }
    }

    /// Swipe-delete on a nearby suggestion tombstones that one location
    /// record, then reloads: the payee legitimately reappears if it has
    /// another recorded location within range.
    private func deleteNearbySuggestion(_ nearby: NearbyPayee) {
        Task { @MainActor in
            guard await budgetStore.deletePayeeLocation(nearby.location) else { return }
            nearbyPayees.removeAll { $0.id == nearby.id }
            loadNearbyPayees()
        }
    }

    private var payeeSuggestions: [Payee] {
        let trimmed = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        return budgetStore.payees
            .filter { payee in
                !payee.tombstone &&
                    payee.transferAccountId == nil &&
                    payee.name.lowercased() != lower &&
                    payee.name.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { lhs, rhs in
                let lp = lhs.name.lowercased().hasPrefix(lower)
                let rp = rhs.name.lowercased().hasPrefix(lower)
                if lp != rp { return lp }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(5)
            .map { $0 }
    }

    private var selectedCategoryName: String {
        guard let id = selectedCategoryId else { return "None" }
        for group in budgetStore.categoryGroups {
            if let match = group.categories.first(where: { $0.id == id }) {
                return match.name
            }
        }
        return "None"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Picker("Type", selection: $txType) {
                            Text("Expense").tag(TransactionType.expense)
                            Text("Income").tag(TransactionType.income)
                            if !isEditing || isEditingTransfer || canConvertToTransfer {
                                Text("Transfer").tag(TransactionType.transfer)
                            }
                        }
                        .pickerStyle(.segmented)
                        // A split parent's sign is the children's; flipping
                        // it would have to flip every line, so it stays fixed.
                        // A transfer stays a transfer: converting one back
                        // would orphan the partner leg (the store refuses it).
                        .disabled(isEditingSplitParent || isEditingTransfer)
                    }

                    HStack {
                        Text(amountSignSymbol)
                            .foregroundStyle(amountSignColor)
                        // The amount is the first thing entered in a fresh
                        // form, so the add flow opens with the keyboard ready.
                        // Edits and prefilled amounts already have one and
                        // start with the keyboard down.
                        AmountInputField(
                            text: $amount,
                            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                            autofocus: !isEditing && amount.isEmpty
                        )
                    }
                }

                Section {
                    Picker(accountPickerLabel, selection: $selectedAccountId) {
                        ForEach(orderedOpenAccounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    .onChange(of: selectedAccountId) { _, newValue in
                        if transferToAccountId == newValue {
                            transferToAccountId = nil
                        }
                    }

                    if isTransfer {
                        Picker(transferPartnerLabel, selection: $transferToAccountId) {
                            Text("Select account").tag(String?.none)
                            ForEach(transferEligibleAccounts) { account in
                                Text(account.name).tag(String?.some(account.id))
                            }
                        }
                        if editedTransferLegIsCategorizable {
                            NavigationLink {
                                CategoryPickerView(selectedCategoryId: $selectedCategoryId) {
                                    userPickedCategory = true
                                }
                            } label: {
                                HStack {
                                    Text("Category")
                                    Spacer()
                                    Text(selectedCategoryName)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        TextField("Payee", text: $payeeName)
                            .focused($payeeFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.words)
                            .onChange(of: payeeName) { _, newValue in
                                if let payee = matchingPayee(for: newValue) {
                                    applyCategoryFromHistory(payeeId: payee.id)
                                }
                            }
                            .onChange(of: payeeFocused) { _, focused in
                                if focused { loadNearbyPayees() }
                                guard focused, !payeeName.isEmpty else { return }
                                DispatchQueue.main.async {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.selectAll(_:)),
                                        to: nil, from: nil, for: nil
                                    )
                                }
                            }

                        if payeeFocused && !payeeSuggestions.isEmpty {
                            ForEach(payeeSuggestions) { payee in
                                Button {
                                    payeeName = payee.name
                                    payeeFocused = false
                                    applyCategoryFromHistory(payeeId: payee.id)
                                } label: {
                                    HStack {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                            .font(.footnote)
                                        Text(payee.name)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                }
                            }
                        }

                        if payeeFocused,
                           payeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           !nearbyPayees.isEmpty {
                            ForEach(nearbyPayees.prefix(5)) { nearby in
                                Button {
                                    payeeName = nearby.payee.name
                                    payeeFocused = false
                                    applyCategoryFromHistory(payeeId: nearby.payee.id)
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
                                        deleteNearbySuggestion(nearby)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        if isEditingSplitParent && !isSplitting && !unsplitRequested {
                            // Placeholder while the children load into the
                            // editable split lines below.
                            HStack {
                                Text("Category")
                                Spacer()
                                Text("Split")
                                    .foregroundStyle(.secondary)
                            }
                        } else if !isSplitting {
                            NavigationLink {
                                CategoryPickerView(selectedCategoryId: $selectedCategoryId) {
                                    userPickedCategory = true
                                }
                            } label: {
                                HStack {
                                    Text("Category")
                                    Spacer()
                                    Text(selectedCategoryName)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if canSplitIntoCategories {
                                Button {
                                    startSplit()
                                } label: {
                                    Label("Split into multiple categories", systemImage: "arrow.triangle.branch")
                                }
                            }
                        }
                    }

                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                if isSplitting && !isTransfer {
                    splitEntrySection
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                    // Links in the note stay openable while the text is a
                    // TextField (GH #190) — this form doubles as the only
                    // full view of a transaction's note.
                    NoteLinkRows(text: notes)
                }

                Section {
                    Toggle("Cleared", isOn: $cleared)
                    // Only the paths that record locations (adds and split
                    // edits) get the per-save opt-out; standard edits never
                    // record, so the toggle would be a no-op there.
                    if (!isEditing || isEditingSplitParent) && !isTransfer
                        && budgetStore.payeeLocationWritesEnabled
                        && budgetStore.recordPayeeLocations {
                        Toggle("Save Location", isOn: $saveLocation)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: { Task { await saveTransaction() } }) {
                        HStack {
                            Spacer()
                            Text(saveButtonTitle)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(saveDisabled)
                    // Hardware-keyboard commit, for the iPad case where the
                    // form is filled without ever leaving the keys. Return on
                    // its own belongs to the focused field; ⌘Return is the
                    // whole form. Inert while the save is disabled.
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .readableWidth()
            .navigationTitle(isEditing ? "Edit Transaction" : "Add Transaction")
            .listSectionSpacing(.compact)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                // Any presented flow (edit, account-detail "+", notification
                // prefill) gets Cancel; the tab-hosted add flow has nothing
                // to dismiss to, so it shows none.
                if isEditing || isPresented {
                    ToolbarItem(placement: .cancellationAction) {
                        // Esc closes the form on a hardware keyboard.
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        payeeFocused = false
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                    .fontWeight(.semibold)
                }
            }
            .disabled(isLoading)
            .task {
                // Load a split parent's children as editable lines. Inherited
                // payees load as empty so a parent payee edit follows through
                // to them, mirroring Actual's cascade rule.
                await loadSplitChildren()
            }
        }
    }

    /// Load a split parent's children as editable lines. Inherited payees
    /// load as empty so a parent payee edit follows through to them,
    /// mirroring Actual's cascade rule. Reused both on first appearance and
    /// when the user undoes an unsplit after swiping the lines away.
    private func loadSplitChildren() async {
        guard let editing, editing.isParent, splitLines.isEmpty else { return }
        splitLines = await budgetStore.fetchSplitChildren(parentId: editing.id).map { child in
            BudgetStore.SplitLineForm(
                childId: child.id,
                categoryId: child.categoryId,
                amount: SplitEntryMath.amountString(fromCents: abs(child.amount)),
                // A child running against the parent's direction — a refund
                // inside a spend split — keeps its flip on reload (GH #216).
                isOpposite: (child.amount < 0) != (editing.amount < 0),
                notes: child.notes ?? "",
                payeeName: (child.payeeName != editing.payeeName ? child.payeeName : nil) ?? ""
            )
        }
    }

    /// Editable split lines for the add flow: one category + amount per
    /// line, with the unassigned remainder in the footer.
    private var splitEntrySection: some View {
        Section {
            ForEach($splitLines) { $line in
                SplitLineRow(line: $line, txType: txType, remainingCents: splitRemainingCents)
            }
            .onDelete { offsets in
                if isEditingSplitParent {
                    // Swiping away every line on an existing parent is the
                    // same intent as "Remove Split": switch to
                    // single-transaction mode and seed the collapse category
                    // from a removed line (the parent carries none). The
                    // lines are gone from memory, so undoing via the split
                    // button reloads them from the database.
                    let removed = offsets.compactMap { splitLines[$0] }
                    splitLines.remove(atOffsets: offsets)
                    if splitLines.isEmpty {
                        unsplitRequested = true
                        if let category = removed.first(where: { $0.categoryId != nil })?.categoryId {
                            selectedCategoryId = category
                        }
                    }
                } else {
                    splitLines.remove(atOffsets: offsets)
                }
            }
            Button {
                splitLines.append(.init())
            } label: {
                Label("Add Line", systemImage: "plus")
            }
            // Tapping "Remove Split" on an existing parent switches the form
            // to single-transaction mode: keep the lines in memory for an
            // instant undo and seed the collapse category from the first
            // line that has one (the parent itself carries none). In the add
            // flow it just clears the lines, as before.
            Button(role: .destructive) {
                if isEditingSplitParent {
                    unsplitRequested = true
                    if let first = splitLines.first(where: { $0.categoryId != nil }) {
                        selectedCategoryId = first.categoryId
                    }
                } else {
                    splitLines = []
                }
            } label: {
                Text("Remove Split")
            }
        } header: {
            Text("Split")
        } footer: {
            if let remaining = splitRemainingCents, remaining != 0 {
                Text("\(budgetStore.formatCurrency(remaining)) left to assign")
                    .foregroundStyle(.red)
            } else if splitRemainingCents == 0 && hasBlankSplitLine {
                // Nothing left to assign but a line is still blank — say why
                // Save stays disabled instead of leaving it a mystery.
                Text("Fill in or remove the empty line")
                    .foregroundStyle(.red)
            }
        }
    }

    /// Begin a split from the form. The add flow starts from two empty
    /// lines; editing a plain transaction seeds the first line with the
    /// transaction's current category and full amount so nothing is lost if
    /// the user only fills the second line — mirroring Actual's desktop
    /// behavior of moving the row's category onto the first sub-row. An
    /// existing parent undoing "Remove Split" just re-enters split mode: the
    /// children were kept in `splitLines`, so nothing needs reloading.
    private func startSplit() {
        unsplitRequested = false
        guard !isEditingSplitParent else {
            // Existing parent: if the lines were kept (Remove Split toggle)
            // they reappear instantly; if they were swiped away, reload them.
            if splitLines.isEmpty {
                Task { await loadSplitChildren() }
            }
            return
        }
        if isEditing {
            splitLines = [
                .init(categoryId: selectedCategoryId, amount: amount),
                .init()
            ]
        } else {
            splitLines = [.init(), .init()]
        }
    }

    private var amountSignSymbol: String {
        switch txType {
        case .expense: return "-"
        case .income: return "+"
        case .transfer: return "→"
        }
    }

    private var amountSignColor: Color {
        switch txType {
        case .expense: return .red
        case .income: return .green
        case .transfer: return .blue
        }
    }

    private var saveButtonTitle: String {
        if isEditing { return "Save Changes" }
        return isTransfer ? "Add Transfer" : "Add Transaction"
    }

    private var saveDisabled: Bool {
        if isLoading || amount.isEmpty { return true }
        if isTransfer && transferToAccountId == nil { return true }
        // A blank line reads as zero for the remainder display, but the store
        // rejects zero-amount children — keep save blocked until it's filled.
        if isSplitting && !isTransfer && (splitRemainingCents != 0 || hasBlankSplitLine) { return true }
        return false
    }

    private func saveTransaction() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let form = BudgetStore.TransactionForm(
            accountId: selectedAccountId,
            type: txType,
            amount: amount,
            payeeName: payeeName,
            transferToAccountId: transferToAccountId,
            categoryId: selectedCategoryId,
            notes: notes,
            date: date,
            cleared: cleared,
            splits: isTransfer ? [] : (unsplitRequested ? [] : splitLines),
            collapseSplit: unsplitRequested,
            recordLocation: saveLocation
        )

        do {
            try await budgetStore.saveTransaction(form, editing: editing)
            if isEditing || isPresented {
                // Presented flows (edit, account-detail "+", notification
                // prefill) close; the account-detail host is already the
                // saved transaction's list.
                dismiss()
            } else {
                // The tab-hosted flow has nothing to dismiss: reset for the
                // next entry and route to the saved transaction's account
                // list so every add flow lands on the relevant list.
                resetForm()
                NotificationRouter.shared.pendingAccountNavigation = form.accountId
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetForm() {
        amount = ""
        txType = .expense
        payeeName = ""
        transferToAccountId = nil
        selectedCategoryId = nil
        notes = ""
        date = Date()
        cleared = false
        errorMessage = nil
        splitLines = []
        unsplitRequested = false
    }
}

/// Math for the split entry section, kept off the view for testability.
enum SplitEntryMath {
    /// Cents still unassigned across the split lines. Blank lines count as
    /// zero so the remainder stays visible mid-entry; nil while the total or
    /// a non-blank line doesn't parse.
    static func remainingCents(total: String, lineAmounts: [String]) -> Int? {
        guard let dollars = Double(total),
              let totalCents = Transaction.cents(fromDollars: dollars) else { return nil }
        var assigned = 0
        for amount in lineAmounts where !amount.isEmpty {
            guard let lineDollars = Double(amount),
                  let cents = Transaction.cents(fromDollars: lineDollars) else { return nil }
            assigned += cents
        }
        return totalCents - assigned
    }

    /// Plain dot-decimal string for non-negative cents, the format
    /// AmountInputField keeps in its binding.
    static func amountString(fromCents cents: Int) -> String {
        "\(cents / 100).\(String(format: "%02d", cents % 100))"
    }
}

/// One editable split line: a category picked through a sheet and an amount.
/// Borderless button so the amount field keeps its own tap target in the row.
private struct SplitLineRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Binding var line: BudgetStore.SplitLineForm
    /// The transaction's direction, so the line's sign glyph can show its
    /// effective direction relative to it.
    var txType: TransactionType
    /// The section-wide unassigned remainder; a positive value on a line with
    /// no amount yet offers one-tap fill instead of mental arithmetic.
    var remainingCents: Int?
    @State private var showCategoryPicker = false

    private var categoryName: String {
        guard let id = line.categoryId else { return "Category" }
        for group in budgetStore.categoryGroups {
            if let match = group.categories.first(where: { $0.id == id }) {
                return match.name
            }
        }
        return "Category"
    }

    /// Whether the line runs as an outflow once the transaction's direction
    /// and the line's flip are combined.
    private var isOutflow: Bool {
        (txType == .expense) != line.isOpposite
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    showCategoryPicker = true
                } label: {
                    Text(categoryName)
                        .foregroundStyle(line.categoryId == nil ? Color.secondary : Color.primary)
                }
                .buttonStyle(.borderless)
                Spacer()
                // Every line carries a sign like the total's, so direction is
                // never implicit; tapping it flips the line — how a refund
                // goes inside a spend split (GH #216).
                Button {
                    line.isOpposite.toggle()
                } label: {
                    Text(isOutflow ? "-" : "+")
                        .foregroundStyle(isOutflow ? Color.red : Color.green)
                        // Grow the tap target beyond the one-character glyph.
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isOutflow ? "Outflow" : "Inflow")
                .accessibilityHint("Flips this line's direction")
                AmountInputField(
                    text: $line.amount,
                    conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                    onToggleSign: { line.isOpposite.toggle() }
                )
                    .frame(width: 110)
            }
            // No fill offer on a flipped line: the remainder is stated in the
            // transaction's direction, and filling it here would double the
            // gap instead of closing it.
            if line.amount.isEmpty, !line.isOpposite, let remaining = remainingCents, remaining > 0 {
                HStack {
                    Spacer()
                    Button {
                        line.amount = SplitEntryMath.amountString(fromCents: remaining)
                    } label: {
                        Text("Use remaining \(budgetStore.formatCurrency(remaining))")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }
            }
            // Empty payee inherits the transaction's payee
            TextField("Payee (optional)", text: $line.payeeName)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
            TextField("Notes (optional)", text: $line.notes)
                .font(.subheadline)
            NoteLinkRows(text: line.notes)
                .font(.subheadline)
        }
        .sheet(isPresented: $showCategoryPicker) {
            NavigationStack {
                CategoryPickerView(selectedCategoryId: $line.categoryId)
            }
        }
    }
}

/// Currency amount field with two digit-entry modes, picked by the
/// `conventionalAmountEntry` setting.
///
/// Calculator entry (the default): digits shift right-to-left into the cents
/// position — typing 1, 2, 0 produces 0.01, 0.12, 1.20. As soon as the user
/// taps `.` (or `,` in comma-decimal locales), the field switches to explicit
/// decimal entry where prior digits are reinterpreted as the integer part —
/// so 1, ., 0 produces 1.0.
///
/// Conventional entry: digits stand for whole units and the decimal separator
/// is always typed — 1, 2, 0 produces 120, and 1, ., 0 produces 1.0. Nothing
/// gains a fraction the user didn't type, so zero-decimal currencies never
/// need a trailing ".00" (GH #211).
///
/// With `allowsNegative`, a ± button joins the keyboard toolbar and flips
/// the text's own sign. With `onToggleSign`, the same button appears but the
/// sign lives outside the field (a split line's direction flip) and the text
/// stays unsigned. Neither set means sign is handled elsewhere entirely
/// (e.g. the expense/income toggle).
///
/// The toolbar also carries +, −, × and ÷ for quick math: typing 12.50, then
/// +, then 6.00 shows "12.50 + 6.00" in the field and collapses to "18.50"
/// when editing ends. Evaluation is strictly left-to-right with no operator
/// precedence — this is an entry aid, not a calculator. The binding always
/// holds the plain evaluated decimal, never the expression, so a save taken
/// mid-expression (the Save button is an ordinary row and doesn't end
/// editing) still commits a parseable amount.
struct AmountInputField: UIViewRepresentable {
    @Binding var text: String
    /// When true, digits are entered as a conventional decimal amount instead
    /// of shifting into cents.
    var conventionalAmountEntry = false
    var alignment: NSTextAlignment = .natural
    var allowsNegative = false
    var weight: UIFont.Weight = .regular
    /// Bring up the keyboard as soon as the field lands on screen. For
    /// sheets whose whole purpose is entering an amount.
    var autofocus = false
    /// Shows the ± toolbar button and delegates it here instead of signing
    /// the text — for callers whose sign is separate state.
    var onToggleSign: (() -> Void)? = nil

    /// becomeFirstResponder is a no-op until the view joins a window, and
    /// during a sheet presentation that happens well after makeUIView —
    /// didMoveToWindow is the earliest reliable moment.
    final class AutofocusTextField: UITextField {
        var wantsAutofocus = false
        private var hasAutofocused = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard wantsAutofocus, !hasAutofocused, window != nil else { return }
            hasAutofocused = true
            becomeFirstResponder()
        }
    }

    func makeUIView(context: Context) -> UITextField {
        let field = AutofocusTextField()
        field.wantsAutofocus = autofocus
        field.keyboardType = .decimalPad
        field.placeholder = conventionalAmountEntry ? "0" : "0.00"
        field.textAlignment = alignment
        field.delegate = context.coordinator
        field.text = text
        if weight == .regular {
            field.font = .preferredFont(forTextStyle: .body)
        } else {
            // Weighted variant of the body style so Dynamic Type still scales.
            let descriptor = UIFontDescriptor
                .preferredFontDescriptor(withTextStyle: .body)
                .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
            field.font = UIFont(descriptor: descriptor, size: 0)
        }
        field.adjustsFontForContentSizeCategory = true
        // The SwiftUI keyboard toolbar only attaches to SwiftUI text fields,
        // and the decimal pad has neither a return key nor operators — without
        // this accessory bar there is no way to dismiss the keyboard from this
        // field, or to do arithmetic in it.
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 100, height: 44))
        var items: [UIBarButtonItem] = []
        if allowsNegative || onToggleSign != nil {
            // The decimal pad has no minus key, so this button is the only
            // keyboard affordance for flipping an amount's sign.
            items.append(UIBarButtonItem(
                image: UIImage(systemName: "plus.forwardslash.minus"),
                style: .plain,
                target: context.coordinator, action: #selector(Coordinator.toggleSign)
            ))
        }
        for op in Coordinator.Operator.allCases {
            let item = UIBarButtonItem(
                image: UIImage(systemName: op.symbolName),
                style: .plain,
                target: context.coordinator, action: op.selector
            )
            item.accessibilityLabel = op.accessibilityLabel
            items.append(item)
        }
        items.append(UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil))
        items.append(UIBarButtonItem(
            title: "Done", style: .done,
            target: field, action: #selector(UIResponder.resignFirstResponder)
        ))
        toolbar.items = items
        toolbar.sizeToFit()
        field.inputAccessoryView = toolbar
        context.coordinator.textField = field
        context.coordinator.sync(fromDisplay: text)
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        // Compare against what the coordinator last wrote out rather than the
        // field's own text: mid-expression the field reads "12.50 + 6.00"
        // while the binding holds "18.50", and that mismatch is expected.
        // Only a change from outside the field should reset the state.
        if text != context.coordinator.lastPublishedText {
            uiView.text = text
            context.coordinator.sync(fromDisplay: text)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        /// The four toolbar operators. Left-to-right evaluation only.
        enum Operator: Character, CaseIterable {
            case add = "+", subtract = "−", multiply = "×", divide = "÷"

            var symbolName: String {
                switch self {
                case .add: return "plus"
                case .subtract: return "minus"
                case .multiply: return "multiply"
                case .divide: return "divide"
                }
            }

            var accessibilityLabel: String {
                switch self {
                case .add: return "Add"
                case .subtract: return "Subtract"
                case .multiply: return "Multiply"
                case .divide: return "Divide"
                }
            }

            var selector: Selector {
                switch self {
                case .add: return #selector(Coordinator.addTapped)
                case .subtract: return #selector(Coordinator.subtractTapped)
                case .multiply: return #selector(Coordinator.multiplyTapped)
                case .divide: return #selector(Coordinator.divideTapped)
                }
            }

            func apply(_ lhs: Double, _ rhs: Double) -> Double {
                switch self {
                case .add: return lhs + rhs
                case .subtract: return lhs - rhs
                case .multiply: return lhs * rhs
                // Dividing by zero has no sensible amount to show, so the
                // operator is dropped and the running total stands.
                case .divide: return rhs == 0 ? lhs : lhs / rhs
                }
            }
        }

        var parent: AmountInputField
        weak var textField: UITextField?
        /// The last value written to the binding, so `updateUIView` can tell
        /// an outside change from the field's own echo.
        private(set) var lastPublishedText: String?
        private var integerDigits: String = ""
        private var hasDecimalPoint: Bool = false
        private var fractionDigits: String = ""
        private var isNegative: Bool = false
        /// Everything to the left of the pending operator, already evaluated.
        private var accumulatedValue: Double?
        private var pendingOperator: Operator?

        init(_ parent: AmountInputField) {
            self.parent = parent
        }

        /// True once the current operand has any content of its own, so a
        /// bare sign or a dangling operator doesn't count as typed input.
        private var hasTypedOperand: Bool {
            !integerDigits.isEmpty || hasDecimalPoint
        }

        func sync(fromDisplay value: String) {
            accumulatedValue = nil
            pendingOperator = nil
            lastPublishedText = value
            isNegative = parent.allowsNegative && value.hasPrefix("-")
            if value.isEmpty {
                integerDigits = ""
                hasDecimalPoint = false
                fractionDigits = ""
                return
            }
            if let dotIdx = value.firstIndex(where: { $0 == "." || $0 == "," }) {
                integerDigits = String(value[..<dotIdx]).filter(\.isWholeNumber)
                hasDecimalPoint = true
                fractionDigits = String(value[value.index(after: dotIdx)...])
                    .filter(\.isWholeNumber)
                    .prefix(2)
                    .map(String.init).joined()
            } else {
                integerDigits = value.filter(\.isWholeNumber)
                hasDecimalPoint = false
                fractionDigits = ""
            }
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let currentLength = (textField.text as NSString?)?.length ?? 0
            let isFullReplace = range.location == 0 && range.length == currentLength && currentLength > 0

            if isFullReplace {
                integerDigits = ""
                hasDecimalPoint = false
                fractionDigits = ""
                isNegative = false
                accumulatedValue = nil
                pendingOperator = nil
            }

            if string.isEmpty {
                handleBackspace()
            } else {
                for character in string {
                    handleCharacter(character)
                }
            }
            applyDisplay(to: textField)
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // Done, tapping away or dismissing the keyboard always leaves a
            // plain amount behind, never a half-finished expression.
            finalizeExpression()
            applyDisplay(to: textField)
        }

        @objc func toggleSign() {
            // Delegated sign lives outside the text (a split line's flip);
            // the field's own text stays unsigned.
            if let onToggleSign = parent.onToggleSign {
                onToggleSign()
                return
            }
            guard parent.allowsNegative else { return }
            isNegative.toggle()
            if let textField {
                applyDisplay(to: textField)
            }
        }

        @objc func addTapped() { pushOperator(.add) }
        @objc func subtractTapped() { pushOperator(.subtract) }
        @objc func multiplyTapped() { pushOperator(.multiply) }
        @objc func divideTapped() { pushOperator(.divide) }

        /// Folds the operand just typed into the running total and arms the
        /// next operator. Tapping a second operator without typing anything
        /// in between just swaps which one is armed.
        private func pushOperator(_ op: Operator) {
            guard accumulatedValue != nil || hasTypedOperand else { return }
            if hasTypedOperand {
                let operand = currentOperandValue()
                if let acc = accumulatedValue, let pending = pendingOperator {
                    accumulatedValue = pending.apply(acc, operand)
                } else {
                    accumulatedValue = operand
                }
                resetOperand()
            }
            pendingOperator = op
            if let textField {
                applyDisplay(to: textField)
            }
        }

        /// Collapses the expression back down to a single editable operand.
        private func finalizeExpression() {
            guard let pending = pendingOperator, let acc = accumulatedValue else { return }
            // A dangling operator ("12.50 ×" then Done) leaves the running
            // total alone rather than multiplying it by an implied zero.
            let result = hasTypedOperand ? pending.apply(acc, currentOperandValue()) : acc
            accumulatedValue = nil
            pendingOperator = nil
            setOperand(to: result)
        }

        /// The value the expression carries so far, evaluated left to right.
        private func resolvedValue() -> Double {
            guard let pending = pendingOperator, let acc = accumulatedValue else {
                return currentOperandValue()
            }
            return hasTypedOperand ? pending.apply(acc, currentOperandValue()) : acc
        }

        private func currentOperandValue() -> Double {
            Double(computeOperandDisplay()) ?? 0
        }

        /// Rounds to cents and drops the sign where the field can't show one
        /// — those callers get their sign from the expense/income toggle, so
        /// the field carries a magnitude and 50 − 80 reads as 30.00.
        private func normalized(_ value: Double) -> Double {
            let signed = parent.allowsNegative ? value : abs(value)
            return (signed * 100).rounded() / 100
        }

        private func resetOperand() {
            integerDigits = ""
            hasDecimalPoint = false
            fractionDigits = ""
            isNegative = false
        }

        /// Loads a computed result back into the digit state so it keeps
        /// behaving like typed input (backspace, another operator, and so on).
        private func setOperand(to value: Double) {
            let rounded = normalized(value)
            let cents = Int((abs(rounded) * 100).rounded())
            isNegative = parent.allowsNegative && rounded < 0
            integerDigits = String(cents / 100)
            // Conventional entry never adds a fraction the user didn't type,
            // so a whole result comes back as a whole number.
            hasDecimalPoint = !(parent.conventionalAmountEntry && cents % 100 == 0)
            fractionDigits = hasDecimalPoint ? String(format: "%02d", cents % 100) : ""
        }

        private func handleCharacter(_ character: Character) {
            // Hardware-keyboard minus; the on-screen path is the ± toolbar button.
            if character == "-", parent.allowsNegative {
                isNegative.toggle()
                return
            }
            if character == "." || character == "," {
                hasDecimalPoint = true
                return
            }
            guard character.isWholeNumber else { return }
            if hasDecimalPoint {
                if fractionDigits.count < 2 {
                    fractionDigits.append(character)
                }
            } else if integerDigits.count < 10 {
                integerDigits.append(character)
            }
        }

        private func handleBackspace() {
            if hasDecimalPoint {
                if !fractionDigits.isEmpty {
                    fractionDigits.removeLast()
                } else {
                    hasDecimalPoint = false
                }
            } else if !integerDigits.isEmpty {
                integerDigits.removeLast()
            } else if isNegative {
                isNegative = false
            } else if pendingOperator != nil {
                // Backspacing through an empty operand undoes the operator and
                // hands the running total back as editable digits.
                pendingOperator = nil
                if let acc = accumulatedValue {
                    setOperand(to: acc)
                }
                accumulatedValue = nil
            }
        }

        /// Just the operand currently being typed, with no running total in
        /// front of it.
        private func computeOperandDisplay() -> String {
            let sign = isNegative ? "-" : ""
            if !hasDecimalPoint && integerDigits.isEmpty {
                // A bare "-" so a sign toggled before any digits stays visible.
                return sign
            }
            if hasDecimalPoint {
                let whole = integerDigits.isEmpty ? "0" : integerDigits
                return sign + whole + "." + fractionDigits
            }
            if parent.conventionalAmountEntry {
                return sign + integerDigits
            }
            let cents = Int(integerDigits) ?? 0
            let dollars = cents / 100
            let pennies = cents % 100
            return "\(sign)\(dollars).\(String(format: "%02d", pennies))"
        }

        /// An evaluated value as the field shows it: two decimals, except in
        /// conventional entry where a whole result stays whole.
        private func displayValue(_ value: Double) -> String {
            let whole = parent.conventionalAmountEntry && value == value.rounded()
            return String(format: whole ? "%.0f" : "%.2f", value)
        }

        /// What the field shows: the running total and armed operator, if any,
        /// followed by the operand being typed.
        private func computeFieldText() -> String {
            let operandText = computeOperandDisplay()
            guard let pending = pendingOperator, let acc = accumulatedValue else {
                return operandText
            }
            let accText = displayValue(acc)
            return operandText.isEmpty
                ? "\(accText) \(pending.rawValue) "
                : "\(accText) \(pending.rawValue) \(operandText)"
        }

        /// What the binding carries: always a plain decimal, so callers can
        /// parse it at any moment — including mid-expression.
        private func computeBoundText() -> String {
            guard pendingOperator != nil, accumulatedValue != nil else {
                return computeOperandDisplay()
            }
            return displayValue(normalized(resolvedValue()))
        }

        private func applyDisplay(to textField: UITextField) {
            textField.text = computeFieldText()
            let bound = computeBoundText()
            lastPublishedText = bound
            if parent.text != bound {
                parent.text = bound
            }
            let end = textField.endOfDocument
            textField.selectedTextRange = textField.textRange(from: end, to: end)
        }
    }
}

/// Searchable category list, shared by the transaction form and the
/// uncategorized-transactions quick-categorize flow.
struct CategoryPickerView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCategoryId: String?
    var onPick: (() -> Void)? = nil
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        List {
            if searchText.isEmpty {
                Button {
                    selectedCategoryId = nil
                    onPick?()
                    dismiss()
                } label: {
                    HStack {
                        Text("None")
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedCategoryId == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }

            ForEach(filteredGroups, id: \.id) { group in
                Section(group.name) {
                    ForEach(group.categories) { category in
                        Button {
                            selectedCategoryId = category.id
                            onPick?()
                            dismiss()
                        } label: {
                            HStack {
                                Text(category.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedCategoryId == category.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Category")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
        .searchFocused($searchFocused)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                searchFocused = true
            }
        }
    }

    private var filteredGroups: [CategoryGroup] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return budgetStore.categoryGroups.filter { !$0.hidden }
        }
        return budgetStore.categoryGroups.compactMap { group in
            let matches = group.categories.filter { category in
                !category.hidden &&
                    (category.name.localizedCaseInsensitiveContains(trimmed) ||
                     group.name.localizedCaseInsensitiveContains(trimmed))
            }
            guard !matches.isEmpty else { return nil }
            var copy = group
            copy.categories = matches
            return copy
        }
    }
}
