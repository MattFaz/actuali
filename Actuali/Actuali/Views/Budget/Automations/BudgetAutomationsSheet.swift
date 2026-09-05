import SwiftUI

/// The visual budget-automations editor (GH #371 follow-up) — SwiftUI port of
/// the web's BudgetAutomationsModal beta (flags.goalTemplatesUIEnabled): a
/// list of the category's automations with live projected contributions, per
/// type editors, options (balance cap, long-term goal, end-of-month cleanup),
/// notes → UI migration, and un-migration back to notes.
struct BudgetAutomationsSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let categoryId: String
    let month: String

    @State private var data: BudgetStore.AutomationEditorData?
    @State private var entries: [AutomationEntry] = []
    @State private var cleanup = CleanupConfig()
    @State private var loadError: String?
    @State private var saving = false
    @State private var editingTarget: AutomationEditorTarget?
    @State private var showingUnmigrate = false
    @State private var totalMonthly = 0
    @State private var contributions: [UUID: Int] = [:]
    @State private var dryRunTask: Task<Void, Never>?

    enum AutomationEditorTarget: Identifiable, Hashable {
        case entry(UUID)
        case cleanup

        var id: String {
            switch self {
            case .entry(let id): id.uuidString
            case .cleanup: "cleanup"
            }
        }
    }

    private var templates: [GoalTemplate] { entries.map(\.template) }

    private var validSources: Set<String> {
        var sources: Set<String> = ["all income", "available funds"]
        for source in data?.incomeSources ?? [] {
            sources.insert(source.id)
            sources.insert(source.name.lowercased())
        }
        return sources
    }

    private func error(for entry: AutomationEntry) -> AutomationError? {
        AutomationValidation.validate(
            entry: entry,
            allTemplates: templates,
            schedules: data?.schedules ?? [],
            currentMonth: BudgetMonthMath.currentMonth(),
            validPercentageSources: validSources)
    }

    private var conflicts: [AutomationConflict] {
        [
            AutomationValidation.percentageAllocationConflict(templates),
            AutomationValidation.schedulePriorityConflict(templates),
        ].compactMap { $0 }
    }

    private var hasErrors: Bool {
        entries.contains { error(for: $0) != nil }
    }

    private var contributionEntries: [AutomationEntry] {
        entries.filter { !AutomationDisplayType.nonContribution.contains($0.displayType) }
    }

    private var limitEntry: AutomationEntry? {
        entries.first { $0.displayType == .limit }
    }

    private var goalEntry: AutomationEntry? {
        entries.first { $0.displayType == .goal }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn't Load Automations",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError))
                } else if let data {
                    if data.hasUnsupportedTemplates {
                        unsupportedNotice
                    } else {
                        editorList(data)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Automations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(data == nil || data?.hasUnsupportedTemplates == true
                            || hasErrors || !conflicts.isEmpty || saving)
                }
            }
            .navigationDestination(item: $editingTarget) { target in
                switch target {
                case .entry(let id):
                    AutomationEntryEditor(
                        entry: entryBinding(id),
                        error: entries.first { $0.id == id }.flatMap(error(for:)),
                        data: data ?? .init(),
                        entries: entries,
                        onAddLimit: { addOption(.limit) },
                        onDelete: {
                            entries.removeAll { $0.id == id }
                            editingTarget = nil
                        })
                case .cleanup:
                    CleanupEditor(
                        cleanup: $cleanup,
                        groups: data?.cleanupGroups ?? [],
                        onCreateGroup: { name in
                            let id = try await budgetStore.resolveCleanupGroup(name: name)
                            if data?.cleanupGroups.contains(where: { $0.id == id }) != true {
                                data?.cleanupGroups.append((id, name))
                            }
                            return id
                        },
                        onDelete: {
                            cleanup = CleanupConfig()
                            editingTarget = nil
                        })
                }
            }
            .sheet(isPresented: $showingUnmigrate) {
                if let data {
                    UnmigrateAutomationsSheet(
                        categoryId: categoryId,
                        initialNote: budgetStore.renderUnmigrateNote(
                            data: data,
                            templates: templates,
                            cleanup: cleanup.toCleanupTemplates()),
                        onDone: { dismiss() })
                }
            }
        }
        .task { await load() }
        .onChange(of: entries.map(\.template)) { _, _ in scheduleDryRun() }
        .interactiveDismissDisabled(saving)
    }

    // MARK: - Screens

    private var unsupportedNotice: some View {
        ContentUnavailableView {
            Label("Unsupported Templates", systemImage: "exclamationmark.triangle")
        } description: {
            Text("This category has template lines the visual editor can't represent. Fix or remove them in the category note first.")
        } actions: {
            Button("Close") { dismiss() }
        }
    }

    @ViewBuilder
    private func editorList(_ data: BudgetStore.AutomationEditorData) -> some View {
        List {
            if data.needsMigration {
                Section {
                    Label(
                        "Imported from notes-based templates. Review and Save to complete the migration.",
                        systemImage: "arrow.up.doc")
                    .font(.footnote)
                    if !data.originalNoteLines.isEmpty {
                        DisclosureGroup("Show original templates") {
                            Text(data.originalNoteLines)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.footnote)
                    }
                }
            }

            ForEach(conflicts, id: \.message) { conflict in
                Section {
                    Label(conflict.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                ForEach(contributionEntries) { entry in
                    entryRow(entry)
                }
                Button {
                    var entry = AutomationEntry(
                        template: BudgetAutomations.defaultTemplate(for: .fixed),
                        displayType: .fixed)
                    entry.template.priority = BudgetAutomations.defaultPriority
                    entries.append(entry)
                    editingTarget = .entry(entry.id)
                } label: {
                    Label("Add Automation", systemImage: "plus")
                }
            } header: {
                Text("Contributions")
            } footer: {
                if !contributionEntries.isEmpty {
                        Text(String(format: String(localized: "Estimated monthly total: %@"), budgetStore.displayBalance(totalMonthly)))
                }
            }

            Section("Options") {
                if let limitEntry {
                    entryRow(limitEntry)
                } else {
                    Button {
                        addOption(.limit)
                    } label: {
                        Label("Add Balance Cap", systemImage: AutomationDisplayType.limit.systemImage)
                    }
                }
                if let goalEntry {
                    entryRow(goalEntry)
                } else {
                    Button {
                        addOption(.goal)
                    } label: {
                        Label("Add Long-Term Goal", systemImage: AutomationDisplayType.goal.systemImage)
                    }
                }
                if cleanup.isConfigured {
                    Button {
                        editingTarget = .cleanup
                    } label: {
                        row(
                            icon: "arrow.3.trianglepath",
                            title: "End of month cleanup",
                            subtitle: cleanupSummary,
                            trailing: nil,
                            isError: false)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        cleanup = CleanupConfig()
                        editingTarget = .cleanup
                    } label: {
                        Label("Add End of Month Cleanup", systemImage: "arrow.3.trianglepath")
                    }
                }
            }

            if !data.needsMigration {
                Section {
                    Button("Switch Back to Notes Templates") {
                        showingUnmigrate = true
                    }
                } footer: {
                    Text("Renders these automations as #template lines into the category note and hands control back to notes-based templates.")
                }
            }
        }
    }

    private var cleanupSummary: String {
        let global = cleanup.global.send || cleanup.global.take
        let scopes = (global ? 1 : 0) + cleanup.groups.count(where: { $0.send || $0.take })
        if scopes > 1 { return "Active in \(scopes) scopes" }
        return global ? "Active globally" : "Active in a pool"
    }

    @ViewBuilder
    private func entryRow(_ entry: AutomationEntry) -> some View {
        let entryError = error(for: entry)
        Button {
            editingTarget = .entry(entry.id)
        } label: {
            row(
                icon: entry.displayType.systemImage,
                title: entry.displayType.label,
                subtitle: entryError?.shortMessage ?? sentence(for: entry.template),
                trailing: AutomationDisplayType.nonContribution.contains(entry.displayType)
                    ? nil : contributions[entry.id].map(budgetStore.displayBalance),
                isError: entryError != nil)
        }
        .buttonStyle(.plain)
    }

    private func row(
        icon: String, title: String, subtitle: String, trailing: String?, isError: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(isError ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isError ? Color.red : Color.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    // MARK: - Actions

    private func sentence(for template: GoalTemplate) -> String {
        AutomationSentences.sentence(
            for: template,
            amount: { budgetStore.displayBalance(BudgetMonthMath.amountToInteger($0)) },
            categoryName: { data?.categoryNames[$0] })
    }

    private func addOption(_ type: AutomationDisplayType) {
        guard !entries.contains(where: { $0.displayType == type }) else { return }
        let entry = AutomationEntry(
            template: BudgetAutomations.defaultTemplate(for: type), displayType: type)
        entries.append(entry)
        editingTarget = .entry(entry.id)
    }

    private func entryBinding(_ id: UUID) -> Binding<AutomationEntry> {
        Binding(
            get: {
                entries.first { $0.id == id }
                    ?? AutomationEntry(
                        template: BudgetAutomations.defaultTemplate(for: .fixed),
                        displayType: .fixed)
            },
            set: { newValue in
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index] = newValue
                }
            })
    }

    private func load() async {
        do {
            let loaded = try await budgetStore.loadAutomationEditor(
                categoryId: categoryId, month: month)
            data = loaded
            entries = loaded.entries
            cleanup = loaded.cleanup
            scheduleDryRun()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func scheduleDryRun() {
        dryRunTask?.cancel()
        guard let data else { return }
        let snapshot = entries
        dryRunTask = Task {
            // Debounce typing, like the web's 200ms debounce.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let result = budgetStore.dryRunAutomations(
                month: month, data: data, templates: snapshot.map(\.template))
            totalMonthly = result.budgeted
            var byEntry: [UUID: Int] = [:]
            for (index, entry) in snapshot.enumerated()
                where index < result.perTemplate.count {
                byEntry[entry.id] = result.perTemplate[index]
            }
            contributions = byEntry
        }
    }

    private func save() async {
        saving = true
        do {
            try await budgetStore.saveAutomations(
                categoryId: categoryId,
                templates: templates,
                cleanup: cleanup.toCleanupTemplates(),
                cleanupGroups: data?.cleanupGroups ?? [])
            dismiss()
        } catch {
            loadError = error.localizedDescription
            saving = false
        }
    }
}

// MARK: - Un-migrate

private struct UnmigrateAutomationsSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let categoryId: String
    let initialNote: String
    let onDone: () -> Void

    @State private var note: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(categoryId: String, initialNote: String, onDone: @escaping () -> Void) {
        self.categoryId = categoryId
        self.initialNote = initialNote
        self.onDone = onDone
        _note = State(initialValue: initialNote)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("We have merged your existing automations with the notes for this category. Please review and edit as needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.body.monospaced())
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.separator)))
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Un-migrate Automations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Un-migrate") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
    }

    private func save() async {
        saving = true
        do {
            try await budgetStore.unmigrateAutomations(categoryId: categoryId, note: note)
            dismiss()
            onDone()
        } catch {
            errorMessage = error.localizedDescription
            saving = false
        }
    }
}
