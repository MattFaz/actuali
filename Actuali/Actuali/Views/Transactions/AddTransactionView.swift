// Actuali/Actuali/Views/Transactions/AddTransactionView.swift

import SwiftUI

struct AddTransactionView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedTab: Int?

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
    @State private var splitLines: [BudgetStore.SplitLineForm] = []

    @FocusState private var payeeFocused: Bool

    /// Initializer for the "Add" flow. The optional prefill parameters carry
    /// whatever a failed Wallet automation received (see TransactionPrefill).
    init(
        accountId: String,
        payee: String = "",
        amountCents: Int? = nil,
        date: Date = Date(),
        selectedTab: Binding<Int?> = .constant(nil)
    ) {
        self.editing = nil
        _selectedAccountId = State(initialValue: accountId)
        _selectedTab = selectedTab
        _amount = State(initialValue: amountCents.map { String(format: "%.2f", Double(abs($0)) / 100.0) } ?? "")
        _txType = State(initialValue: .expense)
        _payeeName = State(initialValue: payee)
        _transferToAccountId = State(initialValue: nil)
        _selectedCategoryId = State(initialValue: nil)
        _notes = State(initialValue: "")
        _date = State(initialValue: date)
        _cleared = State(initialValue: false)
    }

    /// Initializer for the "Edit" flow.
    init(editing: Transaction) {
        self.editing = editing
        _selectedTab = .constant(nil)
        _selectedAccountId = State(initialValue: editing.accountId)

        let cents = abs(editing.amount)
        let dollars = Double(cents) / 100.0
        _amount = State(initialValue: String(format: "%.2f", dollars))
        _txType = State(initialValue: editing.amount < 0 ? .expense : .income)
        _payeeName = State(initialValue: editing.payeeName ?? "")
        _transferToAccountId = State(initialValue: nil)
        _selectedCategoryId = State(initialValue: editing.categoryId)
        _notes = State(initialValue: editing.notes ?? "")
        _date = State(initialValue: Transaction.date(fromYYYYMMDD: editing.date))
        _cleared = State(initialValue: editing.cleared)
    }

    private var isEditing: Bool { editing != nil }
    private var isTransfer: Bool { txType == .transfer }
    private var isEditingSplitParent: Bool { editing?.isParent == true }
    private var isSplitting: Bool { !splitLines.isEmpty }

    /// Cents still unassigned across the split lines, nil while the total or
    /// any line doesn't parse yet.
    private var splitRemainingCents: Int? {
        guard let dollars = Double(amount),
              let total = Transaction.cents(fromDollars: dollars) else { return nil }
        var assigned = 0
        for line in splitLines {
            guard let lineDollars = Double(line.amount),
                  let cents = Transaction.cents(fromDollars: lineDollars) else { return nil }
            assigned += cents
        }
        return total - assigned
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
                            if !isEditing {
                                Text("Transfer").tag(TransactionType.transfer)
                            }
                        }
                        .pickerStyle(.segmented)
                        // A split parent's sign is the children's; flipping
                        // it would have to flip every line, so it stays fixed.
                        .disabled(isEditingSplitParent)
                    }

                    HStack {
                        Text(amountSignSymbol)
                            .foregroundStyle(amountSignColor)
                        AmountInputField(text: $amount)
                    }
                }

                Section {
                    Picker(isTransfer ? "From" : "Account", selection: $selectedAccountId) {
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
                        Picker("To", selection: $transferToAccountId) {
                            Text("Select account").tag(String?.none)
                            ForEach(transferEligibleAccounts) { account in
                                Text(account.name).tag(String?.some(account.id))
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
                            }
                        }

                        if isEditingSplitParent && !isSplitting {
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
                            if !isEditing {
                                Button {
                                    splitLines = [.init(), .init()]
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
                }

                Section {
                    Toggle("Cleared", isOn: $cleared)
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
                }
            }
            .navigationTitle(isEditing ? "Edit Transaction" : "Add Transaction")
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
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
                if let editing, editing.isParent, splitLines.isEmpty {
                    splitLines = await budgetStore.fetchSplitChildren(parentId: editing.id).map { child in
                        BudgetStore.SplitLineForm(
                            childId: child.id,
                            categoryId: child.categoryId,
                            amount: String(format: "%.2f", Double(abs(child.amount)) / 100.0),
                            notes: child.notes ?? "",
                            payeeName: (child.payeeName != editing.payeeName ? child.payeeName : nil) ?? ""
                        )
                    }
                }
            }
        }
    }

    /// Editable split lines for the add flow: one category + amount per
    /// line, with the unassigned remainder in the footer.
    private var splitEntrySection: some View {
        Section {
            ForEach($splitLines) { $line in
                SplitLineRow(line: $line)
            }
            .onDelete { offsets in
                splitLines.remove(atOffsets: offsets)
            }
            Button {
                splitLines.append(.init())
            } label: {
                Label("Add Line", systemImage: "plus")
            }
            // An existing split stays a split — un-splitting would have to
            // collapse the children into the parent, which we don't support.
            if !isEditingSplitParent {
                Button(role: .destructive) {
                    splitLines = []
                } label: {
                    Text("Remove Split")
                }
            }
        } header: {
            Text("Split")
        } footer: {
            if let remaining = splitRemainingCents, remaining != 0 {
                Text("\(budgetStore.formatCurrency(remaining)) left to assign")
                    .foregroundStyle(.red)
            }
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
        if isSplitting && !isTransfer && splitRemainingCents != 0 { return true }
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
            splits: isTransfer ? [] : splitLines
        )

        do {
            try await budgetStore.saveTransaction(form, editing: editing)
            if isEditing {
                dismiss()
            } else {
                resetForm()
                if selectedTab != nil {
                    selectedTab = 0  // Navigate back to Accounts after save
                }
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
    }
}

/// One editable split line: a category picked through a sheet and an amount.
/// Borderless button so the amount field keeps its own tap target in the row.
private struct SplitLineRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Binding var line: BudgetStore.SplitLineForm
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
                AmountInputField(text: $line.amount)
                    .frame(width: 110)
            }
            // Empty payee inherits the transaction's payee
            TextField("Payee (optional)", text: $line.payeeName)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
            TextField("Notes (optional)", text: $line.notes)
                .font(.subheadline)
        }
        .sheet(isPresented: $showCategoryPicker) {
            NavigationStack {
                CategoryPickerView(selectedCategoryId: $line.categoryId)
            }
        }
    }
}

/// Currency amount field with two input modes.
///
/// Default (calculator) mode: digits shift right-to-left into the cents
/// position — typing 1, 2, 0 produces 0.01, 0.12, 1.20. As soon as the user
/// taps `.` (or `,` in comma-decimal locales), the field switches to standard
/// decimal entry where prior digits are reinterpreted as the integer part —
/// so 1, ., 0 produces 1.0.
struct AmountInputField: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.keyboardType = .decimalPad
        field.placeholder = "0.00"
        field.delegate = context.coordinator
        field.text = text
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        context.coordinator.sync(fromDisplay: text)
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
            context.coordinator.sync(fromDisplay: text)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AmountInputField
        private var integerDigits: String = ""
        private var hasDecimalPoint: Bool = false
        private var fractionDigits: String = ""

        init(_ parent: AmountInputField) {
            self.parent = parent
        }

        func sync(fromDisplay value: String) {
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

        private func handleCharacter(_ character: Character) {
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
            }
        }

        private func computeDisplay() -> String {
            if !hasDecimalPoint && integerDigits.isEmpty {
                return ""
            }
            if hasDecimalPoint {
                let whole = integerDigits.isEmpty ? "0" : integerDigits
                return whole + "." + fractionDigits
            }
            let cents = Int(integerDigits) ?? 0
            let dollars = cents / 100
            let pennies = cents % 100
            return "\(dollars).\(String(format: "%02d", pennies))"
        }

        private func applyDisplay(to textField: UITextField) {
            let display = computeDisplay()
            textField.text = display
            if parent.text != display {
                parent.text = display
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
