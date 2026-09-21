import SwiftUI

struct EditTagSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let tagToEdit: Tag?

    @State private var name: String
    @State private var selectedHex: String?
    @State private var customColor: Color = .blue
    @State private var tagDescription: String
    @State private var isHidden: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    init(tag: Tag? = nil) {
        self.tagToEdit = tag
        _name = State(initialValue: tag?.tag ?? "")
        _selectedHex = State(initialValue: tag?.color)
        if let hex = tag?.color, let c = Color(hex: hex) {
            _customColor = State(initialValue: c)
        }
        _tagDescription = State(initialValue: tag?.description ?? "")
        _isHidden = State(initialValue: tag?.hidden ?? false)
    }

    private var isEditing: Bool {
        tagToEdit != nil
    }

    private var normalizedName: String {
        Tag.normalizeTagName(name)
    }

    private var previewText: String {
        normalizedName.isEmpty ? "#tag" : "#\(normalizedName)"
    }

    private var effectiveColorHex: String? {
        selectedHex
    }

    private var previewColor: Color {
        if let hex = selectedHex, let c = Color(hex: hex) {
            return c
        }
        return .accentColor
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Text("#")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        TextField(String(localized: "Tag Name"), text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($nameFocused)
                            .accessibilityIdentifier("editTag.name")
                    }

                    HStack {
                        Text(String(localized: "Preview"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 5) {
                            Circle()
                                .fill(previewColor)
                                .frame(width: 10, height: 10)
                            Text(previewText)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(previewColor.opacity(0.15), in: Capsule())
                    }
                } footer: {
                    Text(String(localized: "Tag names cannot contain spaces or the # symbol."))
                }

                Section(String(localized: "Color")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                        // Default / no custom color button
                        Button {
                            selectedHex = nil
                        } label: {
                            ZStack {
                                Circle()
                                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                                    .background(Circle().fill(Color(.secondarySystemFill)))
                                    .frame(width: 34, height: 34)
                                if selectedHex == nil {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Default Color"))

                        ForEach(Tag.presetColors, id: \.self) { hex in
                            let color = Color(hex: hex) ?? .blue
                            Button {
                                selectedHex = hex
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(color)
                                        .frame(width: 34, height: 34)
                                    if selectedHex == hex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(hex)
                        }
                    }
                    .padding(.vertical, 4)

                    ColorPicker(String(localized: "Custom Color"), selection: $customColor, supportsOpacity: false)
                        .onChange(of: customColor) { _, newColor in
                            selectedHex = newColor.toHex()
                        }
                }

                Section(String(localized: "Description")) {
                    TextField(String(localized: "Description (optional)"), text: $tagDescription)
                        .accessibilityIdentifier("editTag.description")
                }

                if isEditing {
                    Section {
                        Toggle(String(localized: "Hide Tag"), isOn: $isHidden)
                            .accessibilityIdentifier("editTag.hiddenToggle")
                    } footer: {
                        Text(String(localized: "Hidden tags stay on transactions but are hidden from suggestions and primary tag lists."))
                    }

                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            HStack {
                                Spacer()
                                Text(String(localized: "Delete Tag"))
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("editTag.deleteButton")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? String(localized: "Edit Tag") : String(localized: "Add Tag"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(String(localized: "Save")) {
                            Task { await save() }
                        }
                        .disabled(normalizedName.isEmpty)
                        .accessibilityIdentifier("editTag.saveButton")
                    }
                }
            }
            .confirmationDialog(
                String(localized: "Delete this tag?"),
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete Tag"), role: .destructive) {
                    Task { await delete() }
                }
            } message: {
                Text(String(localized: "This removes the tag from your managed tags list. The hashtag will remain on existing transaction notes."))
            }
            .task {
                if !isEditing {
                    nameFocused = true
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil

        let name = normalizedName
        guard Tag.isValidTagName(name) else {
            errorMessage = String(localized: "Tag names cannot contain spaces or the # symbol.")
            isSaving = false
            return
        }

        let desc = tagDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDescription = desc.isEmpty ? nil : desc

        do {
            if let existing = tagToEdit {
                if existing.tag != name {
                    try await budgetStore.renameTag(id: existing.id, oldName: existing.tag, newName: name)
                }
                var updated = existing
                updated.tag = name
                updated.color = selectedHex
                updated.description = resolvedDescription
                updated.hidden = isHidden
                try await budgetStore.updateTag(updated)
            } else {
                try await budgetStore.createTag(
                    name: name,
                    color: selectedHex,
                    description: resolvedDescription
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func delete() async {
        guard let id = tagToEdit?.id else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await budgetStore.deleteTag(id: id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
