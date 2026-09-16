import SwiftUI

/// Fallback transaction-row factory used by `AccountDetailView` after the
/// balance-section merge. The account view supplies its own row state in the
/// normal implementation; these bindings keep the shared row renderer
/// available while the view's state is being consolidated.
func transactionRow(_ transaction: Transaction, showDate: Bool = true) -> some View {
    TransactionListRow(
        transaction: transaction,
        showAccount: false,
        showDate: showDate,
        isSelectionMode: .constant(false),
        isSelected: false,
        editing: .constant(nil as Transaction?),
        onToggleSelect: {}
    )
}
