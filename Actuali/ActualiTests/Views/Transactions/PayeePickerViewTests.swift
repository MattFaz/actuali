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
