import SwiftUI
import Testing
@testable import Actuali

/// The account view's empty-state message picks one of four strings; pin the
/// precedence (chip or search beats the hide toggles) so the branch order
/// survives refactors. The helper is pure for exactly this reason — same
/// seam as `MonthPicker.title`.
struct AccountDetailEmptyStateTests {
    @Test func chipOrSearchGetsTheNeutralMessage() {
        for filter in TransactionStatusFilter.allCases where filter != .all {
            #expect(AccountDetailView.emptyTransactionsText(
                isSearching: false, statusFilter: filter,
                hideCleared: false, hideReconciled: false
            ) == "No matching transactions")
        }
        #expect(AccountDetailView.emptyTransactionsText(
            isSearching: true, statusFilter: .all,
            hideCleared: false, hideReconciled: false
        ) == "No matching transactions")
    }

    @Test func hideTogglesNameThemselvesAndPlainListSaysNothingWasThere() {
        #expect(AccountDetailView.emptyTransactionsText(
            isSearching: false, statusFilter: .all,
            hideCleared: true, hideReconciled: false
        ) == "No uncleared transactions")
        #expect(AccountDetailView.emptyTransactionsText(
            isSearching: false, statusFilter: .all,
            hideCleared: false, hideReconciled: true
        ) == "No unreconciled transactions")
        #expect(AccountDetailView.emptyTransactionsText(
            isSearching: false, statusFilter: .all,
            hideCleared: false, hideReconciled: false
        ) == "No transactions")
    }
}
