import Testing
@testable import Actuali

struct PayeePickerViewTests {
    private func payee(
        id: String,
        name: String,
        tombstone: Bool = false,
        transferAccountId: String? = nil
    ) -> Payee {
        Payee(
            id: id,
            name: name,
            transferAccountId: transferAccountId,
            tombstone: tombstone
        )
    }

    @Test func exactExistingPayeeRemainsSearchable() {
        let walmart = payee(id: "1", name: "Walmart")

        let result = PayeePickerView.filteredPayees(
            from: [walmart],
            searchText: "walmart"
        )

        #expect(result.map(\.id) == ["1"])
    }

    @Test func prefixMatchesSortBeforeSubstringMatches() {
        let grocery = payee(id: "1", name: "Walmart Grocery")
        let shop = payee(id: "2", name: "Super Walmart Shop")

        let result = PayeePickerView.filteredPayees(
            from: [shop, grocery],
            searchText: "Walmart"
        )

        #expect(result.map(\.id) == ["1", "2"])
    }

    @Test func tombstonedAndTransferPayeesAreExcluded() {
        let live = payee(id: "1", name: "Walmart")
        let tombstoned = payee(id: "2", name: "Old Walmart", tombstone: true)
        let transfer = payee(
            id: "3",
            name: "Transfer",
            transferAccountId: "account"
        )

        let result = PayeePickerView.filteredPayees(
            from: [live, tombstoned, transfer],
            searchText: ""
        )

        #expect(result.map(\.id) == ["1"])
    }

    @Test func suggestedPayeesExcludeTombstonesAndTransfers() {
        let live = payee(id: "1", name: "Walmart")
        let tombstoned = payee(id: "2", name: "Old Walmart", tombstone: true)
        let transfer = payee(
            id: "3",
            name: "Transfer",
            transferAccountId: "account"
        )

        let result = PayeePickerView.allowedPayees([
            live,
            tombstoned,
            transfer
        ])

        #expect(result.map(\.id) == ["1"])
    }

    @Test func splitPickerIncludesOtherAccountsTransferPayees() {
        let standard = payee(id: "1", name: "Store")
        let ownAccount = payee(id: "2", name: "", transferAccountId: "checking")
        let savings = payee(id: "3", name: "", transferAccountId: "savings")
        let accounts = [
            Account(id: "checking", name: "Checking", type: .checking,
                    offBudget: false, closed: false, sortOrder: 0, balance: 0),
            Account(id: "savings", name: "Savings", type: .savings,
                    offBudget: false, closed: false, sortOrder: 1, balance: 0),
        ]

        let result = PayeePickerView.filteredPayees(
            from: [standard, ownAccount, savings],
            accounts: accounts,
            transferFromAccountId: "checking",
            searchText: "Savings"
        )

        #expect(result.map(\.id) == ["3"])
    }

    @Test func splitPickerDoesNotDropTransfersBehindPayeeLimit() {
        let standard = (0..<25).map { payee(id: "p\($0)", name: "Payee \($0)") }
        let transfer = payee(id: "transfer", name: "", transferAccountId: "savings")
        let accounts = [
            Account(id: "checking", name: "Checking", type: .checking,
                    offBudget: false, closed: false, sortOrder: 0, balance: 0),
            Account(id: "savings", name: "Savings", type: .savings,
                    offBudget: false, closed: false, sortOrder: 1, balance: 0),
        ]

        let result = PayeePickerView.filteredPayees(
            from: standard + [transfer], accounts: accounts,
            transferFromAccountId: "checking", searchText: "")

        #expect(result.contains { $0.id == "transfer" })
    }

    @Test func committingUnchangedTransferNamePreservesItsId() {
        #expect(PayeePickerView.committedPayeeId(
            currentName: "Transfer: Savings",
            currentId: "transfer",
            committedName: "Transfer: Savings"
        ) == "transfer")
        #expect(PayeePickerView.committedPayeeId(
            currentName: "Transfer: Savings",
            currentId: "transfer",
            committedName: "Coffee Shop"
        ) == nil)
    }

    @Test func customPayeeIsOnlyAllowedWhenNameDoesNotExistCaseInsensitively() {
        let existing = payee(id: "1", name: "Walmart")

        #expect(
            PayeePickerView.canCommitCustomPayee(
                searchText: "Walmart",
                payees: [existing]
            ) == false
        )
        #expect(
            PayeePickerView.canCommitCustomPayee(
                searchText: "Target",
                payees: [existing]
            ) == true
        )
    }
}
