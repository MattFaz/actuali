// Actuali/Actuali/Views/Transactions/AddTransactionView.swift

import SwiftUI

struct AddTransactionView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    private let editing: Transaction?
    /// Called after a successful save (not on cancel). The optional id is the
    /// exact row written by the save path, or nil when nothing was created.
    private let onSaved: ((String?) -> Void)?

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

    init(
        accountId: String,
        payee: String = "",
        amountCents: Int? = nil,
        date: Date = Date(),
        notes: String = "",
        categoryId: String? = nil,
        isIncome: Bool = false,
        cleared: Bool = false,
        onSaved: ((String?) -> Void)? = nil
    ) {
        self.editing = nil
        self.onSaved = onSaved
        _selectedAccountId = State(initialValue: accountId)
        _amount = State(initialValue: amountCents.map { String(format: "%.2f", Double(abs($0)) / 100.0) } ?? "")
        _txType = State(initialValue: isIncome ? .income : .expense)
        _payeeName = State(initialValue: payee)
        _transferToAccountId = State(initialValue: nil)
        _selectedCategoryId = State(initialValue: categoryId)
        _notes = State(initialValue: notes)
        _date = State(initialValue: date)
        _cleared = State(initialValue: cleared)
        _userPickedCategory = State(initialValue: categoryId != nil)
    }

    init(editing: Transaction) {
        self.editing = editing
        self.onSaved = nil

        let cents = abs(editing.amount)
        let dollars = Double(cents) / 100.0
        _amount = State(initialValue: String(format: "%.2f", dollars))
        if editing.transferId != nil {
            _txType = State(initialValue: .transfer)
            if editing.amount < 0 {
                _selectedAccountId = State(initialValue: editing.accountId)
                _transferToAccountId = State(initialValue: editing.transferAcct)
            } else {
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
    private var canDismiss: Bool { isEditing || isPresented }
    private var isTransfer: Bool { txType == .transfer }
    private var isEditingSplitParent: Bool { editing?.isParent == true }
    private var isEditingTransfer: Bool { editing?.transferId != nil }

    private var canConvertToTransfer: Bool {
        guard let editing else { return false }
        return editing.transferId == nil && !editing.isParent && editing.parentId == nil
    }
    private var isConvertingToTransfer: Bool { isTransfer && canConvertToTransfer }

    private var editedTransferLegIsCategorizable: Bool {
        guard let editing, isTransfer else { return false }
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

    private var canSplitIntoCategories: Bool {
        editing?.transferId == nil && (!isEditingSplitParent || unsplitRequested)
    }

    private var splitRemainingCents: Int? {
        SplitEntryMath.remainingCents(total: amount, lineAmounts: splitLines.map { line in
            line.isOpposite && !line.amount.isEmpty ? "-\(line.amount)" : line.amount
        })
    }

    private var hasBlankSplitLine: Bool {
        splitLines.contains { $0.amount.isEmpty }
    }

    private var orderedOpenAccounts: [Account] {
        budgetStore.accounts
            .filter { !$0.closed }
            .sorted { lhs, rhs in
                if lhs.offBudget != rhs.offBudget { return !lhs.offBudget }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

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
            guard !userPickedCategory else { return }
            selectedCategoryId = cat
        }
    }

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
                        .disabled(isEditingSplitParent || isEditingTransfer)
                    }

                    HStack {
                        Text(amountSignSymbol)
                            .foregroundStyle(amountSignColor)
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
                        .lineLimit(1...6)
                    NoteLinkRows(text: notes)
                }

                Section {
                    Toggle("Cleared", isOn: $cleared)
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
                    .keyboardShortcut(.return, modifiers: .command)
                }

                Section {
                    Button(role: .destructive, action: cancelEntry) {
                        HStack {
                            Spacer()
                            Text("Cancel")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .readableWidth()
            .contentMargins(.top, canDismiss ? nil : 8, for: .scrollContent)
            .navigationTitle(canDismiss ? (isEditing ? "Edit Transaction" : "Add Transaction") : "")
            .navigationBarTitleDisplayMode(canDismiss ? .automatic : .inline)
            .listSectionSpacing(.compact)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                        .fontWeight(.semibold)
                }
            }
            .disabled(isLoading)
            .task {
                await loadSplitChildren()
            }
        }
    }

    private func cancelEntry() {
        if canDismiss {
            dismiss()
        } else {
            resetForm()
            NotificationRouter.shared.pendingTabNavigation = StartTab.persisted.tabTag
        }
    }

    private func loadSplitChildren() async {
        guard let editing, editing.isParent, splitLines.isEmpty else { return }
        splitLines = await budgetStore.fetchSplitChildren(parentId: editing.id).map { child in
            BudgetStore.SplitLineForm(
                childId: child.id,
                categoryId: child.categoryId,
                amount: SplitEntryMath.amountString(fromCents: abs(child.amount)),
                isOpposite: (child.amount < 0) != (editing.amount < 0),
                notes: child.notes ?? "",
                payeeName: (child.payeeName != editing.payeeName ? child.payeeName : nil) ?? ""
            )
        }
    }

    private var splitEntrySection: some View {
        Section {
            ForEach($splitLines) { $line in
                SplitLineRow(line: $line, txType: txType, remainingCents: splitRemainingCents)
            }
            .onDelete { offsets in
                if isEditingSplitParent {
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
                Text("Fill in or remove the empty line")
                    .foregroundStyle(.red)
            }
        }
    }

    private func startSplit() {
        unsplitRequested = false
        guard !isEditingSplitParent else {
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
            let savedTransactionId: String?
            if editing == nil && txType == .expense && splitLines.isEmpty {
                savedTransactionId = try await budgetStore.createManualExpenseReturningID(form)
            } else {
                try await budgetStore.saveTransaction(form, editing: editing)
                savedTransactionId = nil
            }

            onSaved?(savedTransactionId)
            if canDismiss {
                dismiss()
            } else {
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
        userPickedCategory = false
        dismissKeyboard()
    }

    private func dismissKeyboard() {
        payeeFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}

/// Math for the split entry section, kept off the view for testability.
enum SplitEntryMath {
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

    static func amountString(fromCents cents: Int) -> String {
        "\(cents / 100).\(String(format: "%02d", cents % 100))"
    }
}

private struct SplitLineRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Binding var line: BudgetStore.SplitLineForm
    var txType: TransactionType
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
                Button {
                    line.isOpposite.toggle()
                } label: {
                    Text(isOutflow ? "-" : "+")
                        .foregroundStyle(isOutflow ? Color.red : Color.green)
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

struct AmountInputField: UIViewRepresentable {
    @Binding var text: String
    var conventionalAmountEntry = false
    var alignment: NSTextAlignment = .natural
    var allowsNegative = false
    var weight: UIFont.Weight = .regular
    var autofocus = false
    var onToggleSign: (() -> Void)? = nil

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
            let descriptor = UIFontDescriptor
                .preferredFontDescriptor(withTextStyle: .body)
                .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
            field.font = UIFont(descriptor: descriptor, size: 0)
        }
        field.adjustsFontForContentSizeCategory = true
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 100, height: 44))
        var items: [UIBarButtonItem] = []
        if allowsNegative || onToggleSign != nil {
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
        let doneStyle: UIBarButtonItem.Style = if #available(iOS 26, *) { .prominent } else { .done }
        items.append(UIBarButtonItem(
            title: "Done", style: doneStyle,
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
        if text != context.coordinator.lastPublishedText {
            uiView.text = text
            context.coordinator.sync(fromDisplay: text)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
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
                case .divide: return rhs == 0 ? lhs : lhs / rhs
                }
            }
        }

        var parent: AmountInputField
        weak var textField: UITextField?
        private(set) var lastPublishedText: String?
        private var integerDigits: String = ""
        private var hasDecimalPoint: Bool = false
        private var fractionDigits: String = ""
        private var isNegative: Bool = false
        private var accumulatedValue: Double?
        private var pendingOperator: Operator?

        init(_ parent: AmountInputField) {
            self.parent = parent
        }

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
            finalizeExpression()
            applyDisplay(to: textField)
        }

        @objc func toggleSign() {
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

        private func finalizeExpression() {
            guard let pending = pendingOperator, let acc = accumulatedValue else { return }
            let result = hasTypedOperand ? pending.apply(acc, currentOperandValue()) : acc
            accumulatedValue = nil
            pendingOperator = nil
            setOperand(to: result)
        }

        private func resolvedValue() -> Double {
            guard let pending = pendingOperator, let acc = accumulatedValue else {
                return currentOperandValue()
            }
            return hasTypedOperand ? pending.apply(acc, currentOperandValue()) : acc
        }

        private func currentOperandValue() -> Double {
            Double(computeOperandDisplay()) ?? 0
        }

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

        private func setOperand(to value: Double) {
            let rounded = normalized(value)
            let cents = Int((abs(rounded) * 100).rounded())
            isNegative = parent.allowsNegative && rounded < 0
            integerDigits = String(cents / 100)
            hasDecimalPoint = !(parent.conventionalAmountEntry && cents % 100 == 0)
            fractionDigits = hasDecimalPoint ? String(format: "%02d", cents % 100) : ""
        }

        private func handleCharacter(_ character: Character) {
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
                pendingOperator = nil
                if let acc = accumulatedValue {
                    setOperand(to: acc)
                }
                accumulatedValue = nil
            }
        }

        private func computeOperandDisplay() -> String {
            let sign = isNegative ? "-" : ""
            if !hasDecimalPoint && integerDigits.isEmpty {
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

        private func displayValue(_ value: Double) -> String {
            let whole = parent.conventionalAmountEntry && value == value.rounded()
            return String(format: whole ? "%.0f" : "%.2f", value)
        }

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

struct CategoryPickerView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCategoryId: String?
    var onPick: (() -> Void)? = nil
    @State private var searchText = ""

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
