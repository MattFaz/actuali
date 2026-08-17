import SwiftUI

/// Create or edit a rule. Same shape as the web editor: a stage, an
/// all/any combinator, a list of conditions and a list of actions.
struct RuleEditorView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    /// Conditions and actions need stable identities for `ForEach` while the
    /// user edits them, and two identical rows are legitimate — so the editor
    /// carries its own ids instead of making the model rows `Identifiable`.
    private struct Row<Value>: Identifiable {
        let id = UUID()
        var value: Value
    }

    private let ruleId: String
    private let isNew: Bool
    @State private var stage: Rule.Stage
    @State private var conditionsOp: Rule.ConditionsOp
    @State private var conditions: [Row<Rule.Condition>]
    @State private var actions: [Row<Rule.Action>]
    @State private var failureMessage: String?
    @State private var isSaving = false

    init(rule: Rule) {
        ruleId = rule.id
        isNew = rule.conditions.isEmpty && rule.actions.isEmpty
        _stage = State(initialValue: rule.stage)
        _conditionsOp = State(initialValue: rule.conditionsOp)
        _conditions = State(initialValue: rule.conditions.map { Row(value: $0) })
        _actions = State(initialValue: rule.actions.map { Row(value: $0) })
    }

    private var draft: Rule {
        Rule(id: ruleId, stage: stage, conditionsOp: conditionsOp,
             conditions: conditions.map(\.value), actions: actions.map(\.value))
    }

    var body: some View {
        Form {
            Section {
                Picker("Stage", selection: $stage) {
                    ForEach(Rule.Stage.allCases, id: \.self) { stage in
                        Text(stage.label).tag(stage)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Pre rules run before everything else, Post rules run last. Most rules belong in Default.")
            }

            Section {
                Picker("Match", selection: $conditionsOp) {
                    Text("all conditions").tag(Rule.ConditionsOp.and)
                    Text("any condition").tag(Rule.ConditionsOp.or)
                }

                ForEach($conditions) { $row in
                    RuleConditionEditor(condition: $row.value)
                }
                .onDelete { conditions.remove(atOffsets: $0) }

                Button {
                    conditions.append(Row(value: .init(op: "is", field: "imported_payee",
                                                       value: .string(""), options: nil)))
                } label: {
                    Label("Add Condition", systemImage: "plus")
                }
            } header: {
                Text("If")
            }

            Section {
                ForEach($actions) { $row in
                    RuleActionEditor(action: $row.value)
                }
                .onDelete { actions.remove(atOffsets: $0) }

                Button {
                    actions.append(Row(value: .init(op: "set", field: "category",
                                                    value: .null, options: nil)))
                } label: {
                    Label("Add Action", systemImage: "plus")
                }
            } header: {
                Text("Then")
            }
        }
        .navigationTitle(isNew ? "New Rule" : "Edit Rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(isSaving || conditions.isEmpty || actions.isEmpty)
            }
        }
        .alert("Couldn't Save Rule", isPresented: Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )) {
            Button("OK") { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await budgetStore.saveRule(draft)
                dismiss()
            } catch {
                failureMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
