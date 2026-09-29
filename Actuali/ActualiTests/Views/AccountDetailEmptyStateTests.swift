import SwiftUI
import Testing
@testable import Actuali

/// The account view's empty-state message picks one of two strings; pin which
/// one each state gets so the rule survives refactors. The helper is pure for
/// exactly this reason — same seam as `MonthPicker.title`.
struct AccountDetailEmptyStateTests {
    @Test func chipOrSearchGetsTheNeutralMessage() {
        for filter in TransactionStatusFilter.allCases where filter != .all {
            #expect(AccountDetailView.emptyTransactionsText(
                isSearching: false, statusFilter: filter
            ) == "No matching transactions")
        }
        #expect(AccountDetailView.emptyTransactionsText(
            isSearching: true, statusFilter: .all
        ) == "No matching transactions")
    }

    @Test func plainListSaysNothingWasThere() {
        #expect(AccountDetailView.emptyTransactionsText(
            isSearching: false, statusFilter: .all
        ) == "No transactions")
    }

    @Test func runningBalanceNeedsAnUnfilteredLoad() {
        #expect(AccountDetailView.allowsRunningBalance(
            isSearching: false, statusFilter: .all
        ))
        #expect(!AccountDetailView.allowsRunningBalance(
            isSearching: true, statusFilter: .all
        ))
        for filter in TransactionStatusFilter.allCases where filter != .all {
            #expect(!AccountDetailView.allowsRunningBalance(
                isSearching: false, statusFilter: filter
            ))
        }
    }

    @Test func noteSectionHidesWhenHiddenOrSearching() {
        #expect(AccountDetailView.showsNote(
            supported: true, hidden: false, isSearching: false
        ))
        #expect(!AccountDetailView.showsNote(
            supported: true, hidden: true, isSearching: false
        ))
        #expect(!AccountDetailView.showsNote(
            supported: true, hidden: false, isSearching: true
        ))
        #expect(!AccountDetailView.showsNote(
            supported: false, hidden: false, isSearching: false
        ))
    }
}
