import SwiftUI

/// Status preset chips above the transaction lists (GH #439), modeled on the
/// Budget tab's check-in strip: one tap narrows the list, the selected chip
/// fills in. Pinned as a top safe-area inset so the list scrolls beneath it.
/// `filters` lets a screen drop chips that can never match there — an
/// off-budget account has no on-budget rows for the uncategorized chip.
struct TransactionFilterStrip: View {
    @Binding var selection: TransactionStatusFilter
    var filters: [TransactionStatusFilter] = TransactionStatusFilter.allCases
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(filters) { filter in
                    Button {
                        selection = filter
                    } label: {
                        Text(filter.label(locale: locale))
                            .filterChip(isSelected: selection == filter)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("transactionFilter-\(filter.rawValue)")
                    .accessibilityAddTraits(selection == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        // The list scrolls under this inset, so give it the page's own
        // background instead of letting rows show through.
        .background(Color(.systemGroupedBackground))
    }
}
