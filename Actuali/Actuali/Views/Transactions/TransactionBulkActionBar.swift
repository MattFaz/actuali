import SwiftUI

struct TransactionBulkActionBar: View {
    let totalCount: Int
    let selectedCount: Int
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onMarkCleared: (Bool) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var showingConfirmDelete = false

    private var allSelected: Bool {
        totalCount > 0 && selectedCount == totalCount
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        onDeselectAll()
                    } else {
                        onSelectAll()
                    }
                }
                .font(.subheadline.weight(.semibold))

                Spacer()

                Menu {
                    Button {
                        onMarkCleared(true)
                    } label: {
                        Label("Mark Cleared", systemImage: "checkmark.circle")
                    }
                    Button {
                        onMarkCleared(false)
                    } label: {
                        Label("Mark Uncleared", systemImage: "circle")
                    }
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.body.weight(.medium))
                        .frame(width: 32, height: 32)
                }
                .disabled(selectedCount == 0)

                Button {
                    onDuplicate()
                } label: {
                    Label(selectedCount > 0 ? "(\(selectedCount))" : "", systemImage: "plus.square.on.square")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(selectedCount == 0)

                Button(role: .destructive) {
                    showingConfirmDelete = true
                } label: {
                    Label(selectedCount > 0 ? "(\(selectedCount))" : "", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(selectedCount == 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial)
        }
        .confirmationDialog(
            "Delete \(selectedCount) transaction(s)?",
            isPresented: $showingConfirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedCount) Transaction\(selectedCount == 1 ? "" : "s")", role: .destructive) {
                onDelete()
            }
        }
    }
}
