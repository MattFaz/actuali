import SwiftUI
import Testing

@testable import Actuali

/// The Credit Cards list orders by urgency rather than by name, and colors each
/// row off the same day count. Both are pure functions so they can be pinned to
/// a fixed `today` here instead of whatever day the suite happens to run on.
@Suite("Credit cards settings")
struct CreditCardsSettingsViewTests {
    private func account(_ name: String) -> Account {
        Account(id: name, name: name, type: .credit, offBudget: false, closed: false, sortOrder: 0, balance: 0)
    }

    // MARK: - Sort order

    /// Feb 20 2026, statement day 15, default 15-day offset: the Feb 15
    /// statement is due Mar 2, ten days out. Statement day 25 is still mid-cycle
    /// on Feb 20, so its next payment is the Feb 25 statement, due Mar 12.
    @Test func sortsBySoonestPaymentNotByName() {
        let today = DayDate(year: 2026, month: 2, day: 20)
        let soon = CreditCardCycle(statementDay: 15)
        let later = CreditCardCycle(statementDay: 25)
        #expect(soon.daysUntilDue(for: today) == 10)
        #expect(later.daysUntilDue(for: today) == 20)

        let sorted = CreditCardsSettingsView.sortedCards(
            [(account: account("Alpha"), cycle: later), (account: account("Zeta"), cycle: soon)],
            today: today
        )
        #expect(sorted.map(\.account.name) == ["Zeta", "Alpha"])
    }

    /// `daysUntilDue` clamps at 0, so past-due cards all tie there. Without the
    /// name tie-break the surviving order comes from a Dictionary, which Swift
    /// reseeds every launch.
    @Test func breaksTiesByNameSoTheOrderIsStable() {
        let today = DayDate(year: 2026, month: 2, day: 20)
        let cycle = CreditCardCycle(statementDay: 15)
        let cards = [
            (account: account("Zeta"), cycle: cycle),
            (account: account("Alpha"), cycle: cycle),
            (account: account("Mid"), cycle: cycle),
        ]
        #expect(CreditCardsSettingsView.sortedCards(cards, today: today).map(\.account.name)
            == ["Alpha", "Mid", "Zeta"])
        // Same set, different input order, same result.
        #expect(CreditCardsSettingsView.sortedCards(cards.reversed(), today: today).map(\.account.name)
            == ["Alpha", "Mid", "Zeta"])
    }

    @Test func sortingAnEmptyListIsEmpty() {
        #expect(CreditCardsSettingsView.sortedCards([]).isEmpty)
    }

    @Test func cardsWithZeroBalanceSortAtTheEnd() {
        let today = DayDate(year: 2026, month: 2, day: 20)
        let soon = CreditCardCycle(statementDay: 15) // due in 10d
        let later = CreditCardCycle(statementDay: 25) // due in 20d

        let paidSoon = Account(id: "1", name: "Paid Soon", type: .credit, offBudget: false, closed: false, sortOrder: 0, balance: 0)
        let unpaidLater = Account(id: "2", name: "Unpaid Later", type: .credit, offBudget: false, closed: false, sortOrder: 0, balance: -5000)
        let unpaidSoon = Account(id: "3", name: "Unpaid Soon", type: .credit, offBudget: false, closed: false, sortOrder: 0, balance: -10000)
        let paidLater = Account(id: "4", name: "Paid Later", type: .credit, offBudget: false, closed: false, sortOrder: 0, balance: 0)

        let cards = [
            (account: paidSoon, cycle: soon),
            (account: unpaidLater, cycle: later),
            (account: unpaidSoon, cycle: soon),
            (account: paidLater, cycle: later),
        ]

        let sorted = CreditCardsSettingsView.sortedCards(cards, today: today)
        #expect(sorted.map(\.account.name) == ["Unpaid Soon", "Unpaid Later", "Paid Soon", "Paid Later"])
    }

    // MARK: - Urgency color

    @Test func urgencyColorSwitchesAtThreeAndSevenDays() {
        #expect(CreditCardCycleRow.urgencyColor(days: 0) == .red)
        #expect(CreditCardCycleRow.urgencyColor(days: 3) == .red)
        #expect(CreditCardCycleRow.urgencyColor(days: 4) == .orange)
        #expect(CreditCardCycleRow.urgencyColor(days: 7) == .orange)
        #expect(CreditCardCycleRow.urgencyColor(days: 8) == .yellow)
        #expect(CreditCardCycleRow.urgencyColor(days: 60) == .yellow)
    }
}
