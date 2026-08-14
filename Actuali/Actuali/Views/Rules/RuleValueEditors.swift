import SwiftUI

/// One condition row: field, operator, and a value editor chosen by the field's
/// type. Field/op lists come from `RuleSchema`, which is the same metadata the
/// engine validates against.
struct RuleConditionEditor: View {
    @EnvironmentObject var budgetStore: BudgetStore
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

            RuleValueEditor(
                value: $condition.value,
                field: condition.field,
                op: condition.op,
                options: $condition.options
            )
        }
    }

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
                condition.op = op
                if wasMulti != isMulti || wasBetween != (op == "isbetween") {
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

                RuleValueEditor(value: $action.value, field: action.field ?? "category",
                                op: "is", options: $action.options)
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
            VStack(alignment: .leading, spacing: 4) {
                TextField(placeholder, text: Binding(
                    get: { value.stringValue ?? "" },
                    set: { value = .string($0) }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

                if op == "matches" {
                    // The engine lowercases the pattern to match upstream, which
                    // silently turns `\D` into `\d`. We can't warn about that
                    // without promising a fix we're not making, but saying the
                    // match is case-insensitive is true, is the part that
                    // actually surprises people, and is the reason `\D` behaves
                    // the way it does.
                    Text("Patterns are matched case-insensitively.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var placeholder: String {
        if op == "matches" { return "Regular expression" }
        return ["oneOf", "notOneOf"].contains(op) ? "Comma-separated values" : "Value"
    }

    /// Payee / category / category group / account. Multi-select ops keep a
    /// list; single ops keep a plain string.
    @ViewBuilder
    private var idPicker: some View {
        if ["oneOf", "notOneOf"].contains(op) {
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

    @ViewBuilder
    private var amountEditor: some View {
        // `AmountInputField` (declared in AddTransactionView.swift) is the
        // app's shared cents entry field; reuse it so rule amounts format and
        // validate like every other amount in the app.
        HStack {
            Text("Amount")
            Spacer()
            AmountInputField(text: Binding(
                get: { value.numberValue.map { String(format: "%.2f", $0 / 100) } ?? "" },
                set: { text in
                    value = .number(Double(Transaction.cents(fromDollars: Double(text) ?? 0) ?? 0))
                }
            ), allowsNegative: true)
            .frame(maxWidth: 140)
        }
        // Upstream exposes amount (inflow) / amount (outflow) as separate
        // fields; here they're a segmented direction on the amount row.
        Picker("Direction", selection: directionBinding) {
            Text("Any").tag("any")
            Text("Inflow").tag("inflow")
            Text("Outflow").tag("outflow")
        }
        .pickerStyle(.segmented)
    }

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

    private var choices: [(id: String, name: String)] {
        switch field {
        case "payee": return budgetStore.payees.map { ($0.id, $0.name) }
        case "category": return budgetStore.categoryGroups.flatMap(\.categories).map { ($0.id, $0.name) }
        case "category_group": return budgetStore.categoryGroups.map { ($0.id, $0.name) }
        case "account": return budgetStore.accounts.filter { !$0.closed }.map { ($0.id, $0.name) }
        default: return []
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
        var ids = selected
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        // Preserve the choice list's order so the rule reads the same every
        // time it round-trips through the editor.
        value = .list(choices.map(\.id).filter(ids.contains).map(RuleValue.string))
    }

    private var choices: [(id: String, name: String)] {
        switch field {
        case "payee": return budgetStore.payees.map { ($0.id, $0.name) }
        case "category": return budgetStore.categoryGroups.flatMap(\.categories).map { ($0.id, $0.name) }
        case "category_group": return budgetStore.categoryGroups.map { ($0.id, $0.name) }
        case "account": return budgetStore.accounts.filter { !$0.closed }.map { ($0.id, $0.name) }
        default: return []
        }
    }
}
