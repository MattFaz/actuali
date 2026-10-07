import Foundation
import Testing
@testable import Actuali

struct AccountsListViewTests {
    private func makeAccount(_ name: String) -> Account {
        Account(
            id: UUID().uuidString,
            name: name,
            type: .checking,
            offBudget: false,
            closed: false,
            sortOrder: 0,
            balance: 0
        )
    }

    private func names(_ query: String, in accounts: [Account]) -> [String] {
        AccountsListView.filterAccounts(accounts, matching: query).map(\.name)
    }

    @Test func filterAccounts() {
        let accounts = [
            "Chequing",
            "Savings",
            "Visa Credit",
            "Tangerine Chequing",
        ].map(makeAccount)

        #expect(names("", in: accounts).count == 4)
        #expect(names("   ", in: accounts).count == 4)
        #expect(names("chequing", in: accounts) == ["Chequing", "Tangerine Chequing"])
        #expect(names("CREDIT", in: accounts) == ["Visa Credit"])
        #expect(names("  savings ", in: accounts) == ["Savings"])
        #expect(names("mortgage", in: accounts).isEmpty)
        #expect(names("i", in: accounts) == [
            "Chequing",
            "Savings",
            "Visa Credit",
            "Tangerine Chequing",
        ])
    }
}
