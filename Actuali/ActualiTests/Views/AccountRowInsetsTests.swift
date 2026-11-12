import SwiftUI
import Testing
@testable import Actuali

/// Account rows set their own inset, so the stock list inset cannot collapse on a
/// wide window. That replacement applies on every device, which is what these
/// cases pin: a phone must keep the stock 16 pt.
@Suite("Account row insets")
struct AccountRowInsetsTests {
    @Test("A phone keeps the stock 16 pt inset on both edges")
    func phoneKeepsStockInset() {
        let insets = AccountsListView.rowInsets(cardMargins: (leading: 0, trailing: 0))

        #expect(insets.leading == 16)
        #expect(insets.trailing == 16)
    }

    @Test("The content moves with the card the margin pulls away from the bar")
    func contentFollowsTheCard() {
        let insets = AccountsListView.rowInsets(cardMargins: (leading: 0, trailing: 20))

        #expect(insets.leading == 16)
        #expect(insets.trailing == 36)
    }

    @Test("A bar on the leading edge moves the leading inset instead")
    func leadingBar() {
        let insets = AccountsListView.rowInsets(cardMargins: (leading: 20, trailing: 0))

        #expect(insets.leading == 36)
        #expect(insets.trailing == 16)
    }
}
