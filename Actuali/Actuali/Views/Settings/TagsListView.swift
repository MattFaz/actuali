import SwiftUI

struct TagsListView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale

    @State private var searchText = ""
    @State private var isCreating = false
    @State private var editingTag: Tag?
    @State private var showHidden = false
    @State private var discoveryMessage: String?
    @State private var errorMessage: String?
    @State private var tagToDelete: Tag?

    private var summariesByTagId: [String: TagSummary] {
        Dictionary(uniqueKeysWithValues: budgetStore.tagSummaries.map { ($0.tag.id, $0) })
    }

    private var filteredTags: [Tag] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return budgetStore.tags
            .filter { tag in
                if tag.tombstone {
                    return false
                }
                if !showHidden && tag.hidden {
                    return false
                }
                if query.isEmpty {
                    return true
                }
                let nameMatch = tag.tag.lowercased().contains(query)
                let descMatch = tag.description?.lowercased().contains(query) ?? false
                return nameMatch || descMatch
            }
            .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
    }

    var body: some View {
        Group {
            if budgetStore.tags.isEmpty, !budgetStore.isLoading {
                ContentUnavailableView {
                    Label(String(localized: "No Tags"), systemImage: "number")
                } description: {
                    Text(String(localized: "Tags let you flag and categorize transactions with #hashtags in notes."))
                } actions: {
                    VStack(spacing: 12) {
                        Button(String(localized: "Add Tag")) {
                            isCreating = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button(String(localized: "Find Existing Tags")) {
                            Task { await discoverTags() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if filteredTags.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filteredTags) { tag in
                        NavigationLink {
                            TagTransactionsView(tag: tag)
                        } label: {
                            tagRow(tag)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                tagToDelete = tag
                            } label: {
                                Label(String(localized: "Delete"), systemImage: "trash")
                            }

                            Button {
                                editingTag = tag
                            } label: {
                                Label(String(localized: "Edit"), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                editingTag = tag
                            } label: {
                                Label(String(localized: "Edit Tag"), systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                tagToDelete = tag
                            } label: {
                                Label(String(localized: "Delete Tag"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Tags"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(String(localized: "Search tags"))
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Label(String(localized: "Add Tag"), systemImage: "plus")
                }
                .accessibilityIdentifier("tagsList.addButton")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await discoverTags() }
                    } label: {
                        Label(String(localized: "Find Existing Tags"), systemImage: "magnifyingglass")
                    }

                    Toggle(String(localized: "Show Hidden Tags"), isOn: $showHidden)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("tagsList.menuButton")
            }
        }
        .refreshable {
            await budgetStore.refreshTagSummaries()
        }
        .sheet(isPresented: $isCreating) {
            EditTagSheet()
        }
        .sheet(item: $editingTag) { tag in
            EditTagSheet(tag: tag)
        }
        .confirmationDialog(
            String(localized: "Delete this tag?"),
            isPresented: Binding(
                get: { tagToDelete != nil },
                set: {
                    if !$0 {
                        tagToDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete Tag"), role: .destructive) {
                if let tag = tagToDelete {
                    Task { await delete(tag) }
                }
            }
        } message: {
            Text(String(localized: "This removes the tag from your managed tags list. The hashtag will remain on existing transaction notes."))
        }
        .alert(
            String(localized: "Discovery"),
            isPresented: Binding(
                get: { discoveryMessage != nil },
                set: {
                    if !$0 {
                        discoveryMessage = nil
                    }
                }
            )
        ) {
            Button(String(localized: "OK")) { discoveryMessage = nil }
        } message: {
            Text(discoveryMessage ?? "")
        }
        .alert(
            String(localized: "Error"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button(String(localized: "OK")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func tagRow(_ tag: Tag) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(tag.swiftUIColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tag.displayName)
                        .font(.body.weight(.semibold))

                    if tag.hidden {
                        Text(String(localized: "Hidden"))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.secondarySystemFill), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }

                if let desc = tag.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let summary = summariesByTagId[tag.id] {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(budgetStore.displaySpentCaption(summary.netAmount))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(summary.netAmount > 0 ? .green : .primary)

                    Text(String(format: String(localized: "%lld txs"), Int64(summary.transactionCount)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tagRow.\(tag.tag)")
    }

    private func discoverTags() async {
        do {
            let found = try await budgetStore.discoverTags()
            if found.isEmpty {
                discoveryMessage = String(localized: "No new tags found in transaction notes.")
            } else {
                discoveryMessage = String(format: String(localized: "Found and added %lld tags: %@"), Int64(found.count), found.map(\.displayName).joined(separator: ", "))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ tag: Tag) async {
        do {
            try await budgetStore.deleteTag(id: tag.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
