import SwiftUI

/// The pickable rows for an id-typed rule field. Transfer payees (the
/// empty-named payee each account owns) and hidden categories are filtered out
/// the same way the transaction form filters them — they aren't things a user
/// writes a rule against.
/// `@MainActor` because it reads `BudgetStore`, which is main-actor isolated;
/// every caller is a View member and already on the main actor.
@MainActor
private func ruleChoices(for field: String, in store: BudgetStore) -> [(id: String, name: String)] {
    switch field {
    case "payee":
        return store.payees
            .filter { !$0.tombstone && $0.transferAccountId == nil }
            .map { ($0.id, $0.name) }
    case "category":
        return store.categoryGroups
            .filter { !$0.hidden }
            .flatMap(\.categories)
            .filter { !$0.hidden }
            .map { ($0.id, $0.name) }
    case "category_group":
        return store.categoryGroups
            .filter { !$0.hidden }
            .map { ($0.id, $0.name) }
    case "account":
        return store.accounts
            .filter { !$0.closed }
            .map { ($0.id, $0.name) }
    default:
        return []
    }
}

/// One condition row: field, operator, and a value editor chosen by the field's
/// type. Field/op lists come from `RuleSchema`, which is the same metadata the
/// engine validates against.
struct RuleConditionEditor: View {
    @Binding var condition: Rule.Condition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Field", selection: fieldBinding) {
                    ForEach(RuleSchema.conditionFields, id: \.self) { field in
                        Text(RuleSchema.label(field: field).capitalized).tag(field)
                    }
                }
                .labelsHidden()

                Picker("Operator", selection: opBinding) {
                    ForEach(RuleSchema.validOps(for: condition.field), id: \.self) { op in
                        Text(RuleSchema.label(op: op, type: RuleSchema.fieldType(condition.field))).tag(op)
                    }
                }
                .labelsHidden()
            }

            // onBudget/offBudget read the account, not a value; upstream hides
            // the value input for them.
            if !Self.valuelessOps.contains(condition.op) {
                RuleValueEditor(
                    value: $condition.value,
                    field: condition.field,
                    op: condition.op,
                    options: $condition.options,
                    showsDirection: true
                )
            }
        }
    }

    private static let valuelessOps: Set<String> = ["onBudget", "offBudget"]

    /// Changing the field can invalidate the operator and the value shape, so
    /// both reset the way the web editor does.
    private var fieldBinding: Binding<String> {
        Binding(
            get: { condition.field },
            set: { field in
                condition.field = field
                if !RuleSchema.isValidOp(field: field, op: condition.op) {
                    condition.op = RuleSchema.validOps(for: field).first ?? "is"
                }
                condition.value = RuleValueEditor.defaultValue(field: field, op: condition.op)
                // Inflow/outflow only means anything on an amount.
                if RuleSchema.fieldType(field) != .number {
                    condition.options = nil
                }
            }
        )
    }

    private var opBinding: Binding<String> {
        Binding(
            get: { condition.op },
            set: { op in
                let wasMulti = ["oneOf", "notOneOf"].contains(condition.op)
                let isMulti = ["oneOf", "notOneOf"].contains(op)
                let wasBetween = condition.op == "isbetween"
                let wasValueless = Self.valuelessOps.contains(condition.op)
                let isValueless = Self.valuelessOps.contains(op)
                condition.op = op
                if isValueless {
                    condition.value = .null
                } else if wasMulti != isMulti || wasBetween != (op == "isbetween") || wasValueless {
                    condition.value = RuleValueEditor.defaultValue(field: condition.field, op: op)
                }
            }
        )
    }
}

/// One action row: `set <field> to <value>`, plus the note ops.
struct RuleActionEditor: View {
    @Binding var action: Rule.Action

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Action", selection: opBinding) {
                ForEach(["set", "prepend-notes", "append-notes", "delete-transaction"], id: \.self) { op in
                    Text(RuleSchema.label(op: op).capitalized).tag(op)
                }
            }
            .labelsHidden()

            if action.op == "set" {
                Picker("Field", selection: fieldBinding) {
                    ForEach(RuleSchema.actionFields, id: \.self) { field in
                        Text(RuleSchema.label(field: field).capitalized).tag(field)
                    }
                }
                .labelsHidden()

                // `op: "is"` because an action's value is always a single one —
                // the multi-value and between shapes are condition-only. No
                // direction either: a `set amount` has no inflow/outflow.
                RuleValueEditor(
                    value: $action.value,
                    field: action.field ?? "category",
                    op: "is",
                    options: $action.options
                )
            } else if action.op != "delete-transaction" {
                TextField("Text", text: Binding(
                    get: { action.value.stringValue ?? "" },
                    set: { action.value = .string($0) }
                ))
            }
        }
    }

    private var opBinding: Binding<String> {
        Binding(
            get: { action.op },
            set: { op in
                action.op = op
                switch op {
                case "set":
                    action.field = action.field ?? "category"
                    action.value = .null
                case "delete-transaction":
                    action.field = nil
                    action.value = .null
                default:
                    action.field = "notes"
                    action.value = .string("")
                }
            }
        )
    }

    private var fieldBinding: Binding<String> {
        Binding(
            get: { action.field ?? "category" },
            set: { field in
                action.field = field
                action.value = RuleValueEditor.defaultValue(field: field, op: "is")
            }
        )
    }
}

/// The value half of a condition or action, shaped by the field's type.
struct RuleValueEditor: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Binding var value: RuleValue
    let field: String
    let op: String
    @Binding var options: [String: RuleValue]?
    /// Inflow/outflow is a condition-only concept — a `set amount` action has no
    /// direction. Defaults off so callers opt in.
    var showsDirection: Bool = false

    /// The empty value for a freshly chosen field/op pair.
    static func defaultValue(field: String, op: String) -> RuleValue {
        if ["oneOf", "notOneOf"].contains(op) { return .list([]) }
        if op == "isbetween" { return .object(["num1": .number(0), "num2": .number(0)]) }
        switch RuleSchema.fieldType(field) {
        case .number: return .number(0)
        case .boolean: return .bool(true)
        case .date, .string: return .string("")
        case .id, .none: return .null
        }
    }

    var body: some View {
        switch RuleSchema.fieldType(field) {
        case .id:
            idPicker
        case .number:
            amountEditor
        case .date:
            datePicker
        case .boolean:
            Toggle("Value", isOn: Binding(
                get: { value.boolValue ?? false },
                set: { value = .bool($0) }
            ))
        case .string, .none:
            textEditor
        }
    }

    private var isMultiValue: Bool { ["oneOf", "notOneOf"].contains(op) }

    private var choices: [(id: String, name: String)] {
        ruleChoices(for: field, in: budgetStore)
    }

    private var placeholder: String {
        if op == "matches" { return "Regular expression" }
        return isMultiValue ? "Comma-separated values" : "Value"
    }

    // MARK: - Text

    @ViewBuilder
    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isMultiValue {
                // oneOf/notOneOf carry a list, not a string. Editing it as
                // comma-separated text keeps the row a single field while still
                // producing the shape the engine matches on — a plain string
                // here would never match and couldn't be saved.
                TextField(placeholder, text: Binding(
                    get: { (value.listValue ?? []).compactMap(\.stringValue).joined(separator: ", ") },
                    set: { text in
                        value = .list(
                            text.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                                .map(RuleValue.string)
                        )
                    }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } else {
                TextField(placeholder, text: Binding(
                    get: { value.stringValue ?? "" },
                    set: { value = .string($0) }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            }

            if op == "matches" {
                // The engine lowercases the pattern to match upstream, which
                // silently turns `\D` into `\d`. We can't warn about that
                // without promising a fix we're not making, but saying the match
                // is case-insensitive is true, is the part that actually
                // surprises people, and is the reason `\D` behaves as it does.
                Text("Patterns are matched case-insensitively.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Ids

    /// Payee / category / category group / account. Multi-select ops keep a
    /// list; single ops keep a plain string.
    @ViewBuilder
    private var idPicker: some View {
        if isMultiValue {
            NavigationLink {
                RuleIdMultiPicker(field: field, value: $value)
            } label: {
                LabeledContent("Values", value: "\(value.listValue?.count ?? 0) selected")
            }
        } else {
            Picker("Value", selection: Binding(
                get: { value.stringValue ?? "" },
                set: { value = $0.isEmpty ? .null : .string($0) }
            )) {
                Text("Nothing").tag("")
                ForEach(choices, id: \.id) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
        }
    }

    // MARK: - Amounts

    @ViewBuilder
    private var amountEditor: some View {
        if op == "isbetween" {
            // A between value is a `{num1, num2}` object; feeding it to the
            // single-amount field would clobber it with a scalar the engine
            // can't evaluate and the web client refuses to load.
            RuleAmountField(label: "From", value: betweenBinding("num1"))
            RuleAmountField(label: "To", value: betweenBinding("num2"))
        } else {
            RuleAmountField(value: $value)
        }

        if showsDirection {
            // Upstream exposes amount (inflow) / amount (outflow) as separate
            // fields; here they're a segmented direction on the amount row.
            Picker("Direction", selection: directionBinding) {
                Text("Any").tag("any")
                Text("Inflow").tag("inflow")
                Text("Outflow").tag("outflow")
            }
            .pickerStyle(.segmented)
        }
    }

    /// One endpoint of a `{num1, num2}` between value. Writing an endpoint
    /// rebuilds the object so a malformed value self-heals into the shape the
    /// engine and the web client require.
    private func betweenBinding(_ key: String) -> Binding<RuleValue> {
        Binding(
            get: {
                guard case .object(let dict) = value, let endpoint = dict[key] else { return .null }
                return endpoint
            },
            set: { newValue in
                var dict: [String: RuleValue] = [:]
                if case .object(let existing) = value { dict = existing }
                dict[key] = newValue
                if dict["num1"] == nil { dict["num1"] = .number(0) }
                if dict["num2"] == nil { dict["num2"] = .number(0) }
                value = .object(dict)
            }
        )
    }

    private var directionBinding: Binding<String> {
        Binding(
            get: {
                if options?["inflow"]?.boolValue == true { return "inflow" }
                if options?["outflow"]?.boolValue == true { return "outflow" }
                return "any"
            },
            set: { direction in
                switch direction {
                case "inflow": options = ["inflow": .bool(true)]
                case "outflow": options = ["outflow": .bool(true)]
                default: options = nil
                }
            }
        )
    }

    // MARK: - Dates

    private var datePicker: some View {
        DatePicker("Date", selection: Binding(
            get: {
                guard let text = value.stringValue,
                      let day = Int(text.replacingOccurrences(of: "-", with: "")), day > 9_999_999
                else { return Date() }
                return Transaction.date(fromYYYYMMDD: day)
            },
            set: { date in
                let ymd = Transaction.yyyymmdd(from: date)
                value = .string(String(format: "%04d-%02d-%02d", ymd / 10000, (ymd % 10000) / 100, ymd % 100))
            }
        ), displayedComponents: .date)
    }
}

/// Cents entry for a rule amount. Holds its own text the way the rest of the app
/// does (`AddTransactionView`) and commits through `AmountParser`, so partial
/// input ("10.", "1,50") isn't destroyed mid-keystroke — a binding that reparsed
/// on every character would zero the value as the user typed.
private struct RuleAmountField: View {
    var label = "Amount"
    @Binding var value: RuleValue
    @State private var text = ""

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            AmountInputField(text: $text, allowsNegative: true)
                .frame(maxWidth: 140)
        }
        .onAppear {
            guard text.isEmpty, let cents = value.numberValue else { return }
            text = String(format: "%.2f", cents / 100)
        }
        .onChange(of: text) { _, newText in
            // An unparseable partial entry leaves the stored value alone; Save
            // is what ultimately validates it.
            guard let dollars = AmountParser.parse(newText),
                  let cents = Transaction.cents(fromDollars: dollars) else { return }
            value = .number(Double(cents))
        }
    }
}

/// Multi-select for `oneOf` / `notOneOf` id conditions.
struct RuleIdMultiPicker: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let field: String
    @Binding var value: RuleValue

    private var selected: Set<String> {
        Set((value.listValue ?? []).compactMap(\.stringValue))
    }

    private var choices: [(id: String, name: String)] {
        ruleChoices(for: field, in: budgetStore)
    }

    var body: some View {
        List(choices, id: \.id) { choice in
            Button {
                toggle(choice.id)
            } label: {
                HStack {
                    Text(choice.name)
                    Spacer()
                    if selected.contains(choice.id) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(RuleSchema.label(field: field).capitalized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ id: String) {
        value = Self.toggling(id, in: value, visibleIds: choices.map(\.id))
    }

    /// Toggle `id`, keeping visible ids in the choice list's order so the rule
    /// reads the same every time it round-trips through the editor — and
    /// keeping ids the picker can't display (hidden categories, closed
    /// accounts, rules authored on another client), which toggling an
    /// unrelated item must not silently drop.
    nonisolated static func toggling(_ id: String, in value: RuleValue, visibleIds: [String]) -> RuleValue {
        var ids = Set((value.listValue ?? []).compactMap(\.stringValue))
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        let visible = visibleIds.filter(ids.contains)
        let hidden = (value.listValue ?? []).compactMap(\.stringValue)
            .filter { ids.contains($0) && !visibleIds.contains($0) }
        return .list((visible + hidden).map(RuleValue.string))
    }
}
