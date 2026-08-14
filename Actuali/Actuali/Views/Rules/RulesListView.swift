import SwiftUI

/// Manage the rules Actual applies to incoming transactions (GH #222).
/// Mirrors the web's mobile rules page: stage badge, an IF/THEN summary per
/// rule, search over that summary text, and swipe to delete.
struct RulesListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var searchText = ""
    @State private var editingRule: Rule?
    @State private var isCreating = false
    @State private var failureMessage: String?
    @State private var hasLoaded = false

    private var summary: RuleSummary { budgetStore.ruleSummary }

    private var filteredRules: [Rule] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return budgetStore.rules }
        return budgetStore.rules.filter { summary.searchText($0).contains(query) }
    }

    var body: some View {
        Group {
            if !budgetStore.rulesSupported && hasLoaded {
                ContentUnavailableView(
                    "Rules Unavailable",
                    systemImage: "slider.horizontal.3",
                    description: Text("This budget file has no rules table. Open it in Actual once to add one.")
                )
            } else if budgetStore.rules.isEmpty && hasLoaded {
                ContentUnavailableView {
                    Label("No Rules", systemImage: "slider.horizontal.3")
                } description: {
                    Text("Rules rewrite transactions as they're added — renaming payees, setting categories, and more.")
                } actions: {
                    Button("Create Rule") { isCreating = true }
                }
            } else if hasLoaded {
                List {
                    Section {
                        ForEach(filteredRules) { rule in
                            Button {
                                editingRule = rule
                            } label: {
                                RuleRow(rule: rule, summary: summary,
                                        isOwnedBySchedule: budgetStore.scheduleOwnedRuleIds.contains(rule.id))
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                if !budgetStore.scheduleOwnedRuleIds.contains(rule.id) {
                                    Button("Delete", role: .destructive) { delete(rule) }
                                }
                            }
                        }
                    } footer: {
                        Text("Rules run in stage order: Pre, then Default, then Post, within a stage the most specific rule runs last.")
                    }
                }
                .searchable(text: $searchText, prompt: "Search rules")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if budgetStore.rulesSupported {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            NavigationStack { RuleEditorView(rule: rule) }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack { RuleEditorView(rule: .empty()) }
        }
        .alert("Couldn't Delete Rule", isPresented: Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )) {
            Button("OK") { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
        .task {
            await budgetStore.loadRules()
            hasLoaded = true
        }
        .refreshable { await budgetStore.loadRules() }
    }

    private func delete(_ rule: Rule) {
        Task {
            do {
                try await budgetStore.deleteRule(rule)
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }
}

/// One rule: stage badge, the conditions under IF, the actions under THEN.
private struct RuleRow: View {
    let rule: Rule
    let summary: RuleSummary
    let isOwnedBySchedule: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(rule.stage.label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stageColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(stageColor)
                if isOwnedBySchedule {
                    Label("Schedule", systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            labelled("IF", lines: rule.conditions.map(summary.condition),
                     joiner: rule.conditionsOp == .and ? "and" : "or")
            labelled("THEN", lines: rule.actions.map(summary.action), joiner: nil)
        }
        .padding(.vertical, 2)
    }

    private var stageColor: Color {
        switch rule.stage {
        case .pre: return .blue
        case .default: return .secondary
        case .post: return .orange
        }
    }

    /// `joiner` prefixes every line but the first ("and"/"or"), the way
    /// `RuleRow.tsx` renders `prefix={i > 0 ? conditionsOp : null}`.
    private func labelled(_ title: String, lines: [String], joiner: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(index > 0 ? "\(joiner.map { $0 + " " } ?? "")\(line)" : line)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
