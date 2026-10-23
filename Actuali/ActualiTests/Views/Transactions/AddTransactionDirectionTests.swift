import Testing
@testable import Actuali

/// The single-page form has no type control: the amount's sign gives the
/// direction and an account chosen as the payee makes a transfer, as in Actual.
struct AddTransactionDirectionTests {
    @Test func theSignAloneDecidesExpenseOrIncome() {
        #expect(AddTransactionView.type(isTransfer: false, isInflow: false) == .expense)
        #expect(AddTransactionView.type(isTransfer: false, isInflow: true) == .income)
    }

    @Test func anAccountPayeeMakesATransferWhateverTheSign() {
        #expect(AddTransactionView.type(isTransfer: true, isInflow: false) == .transfer)
        #expect(AddTransactionView.type(isTransfer: true, isInflow: true) == .transfer)
    }

    @Test func moneyOutGoesFromThisAccountToThePartner() {
        let ends = AddTransactionView.transferEnds(
            accountId: "checking", partnerId: "savings", isInflow: false, keepsOwnSide: false
        )
        #expect(ends.from == "checking")
        #expect(ends.to == "savings")
    }

    @Test func moneyInComesFromThePartnerIntoThisAccount() {
        let ends = AddTransactionView.transferEnds(
            accountId: "checking", partnerId: "savings", isInflow: true, keepsOwnSide: false
        )
        #expect(ends.from == "savings")
        #expect(ends.to == "checking")
    }

    @Test func convertingARowKeepsItOnItsOwnSideWhateverTheSign() {
        // The store reads the direction off the original row, so the form
        // hands it this account first either way.
        for inflow in [false, true] {
            let ends = AddTransactionView.transferEnds(
                accountId: "checking", partnerId: "savings", isInflow: inflow, keepsOwnSide: true
            )
            #expect(ends.from == "checking")
            #expect(ends.to == "savings")
        }
    }

    @Test func categoryPickerMovesIncomeGroupsToTheEndWithoutReorderingGroups() {
        let groups = [
            CategoryGroup(
                id: "bills",
                name: "Bills",
                isIncome: false,
                hidden: false,
                sortOrder: 1,
                categories: []
            ),
            CategoryGroup(
                id: "income",
                name: "Income",
                isIncome: true,
                hidden: false,
                sortOrder: 2,
                categories: []
            ),
            CategoryGroup(
                id: "food",
                name: "Food",
                isIncome: false,
                hidden: false,
                sortOrder: 3,
                categories: []
            ),
            CategoryGroup(
                id: "starting-balances",
                name: "Starting Balances",
                isIncome: true,
                hidden: false,
                sortOrder: 4,
                categories: []
            ),
        ]

        #expect(
            CategoryPickerView.incomeLast(groups).map(\.id)
                == ["bills", "food", "income", "starting-balances"]
        )
    }

    @Test func categoryPickerKeepsOrderWhenNoIncomeGroupsExist() {
        let groups = [
            CategoryGroup(
                id: "bills",
                name: "Bills",
                isIncome: false,
                hidden: false,
                sortOrder: 2,
                categories: []
            ),
            CategoryGroup(
                id: "food",
                name: "Food",
                isIncome: false,
                hidden: false,
                sortOrder: 1,
                categories: []
            ),
        ]

        #expect(CategoryPickerView.incomeLast(groups).map(\.id) == ["bills", "food"])
        #expect(CategoryPickerView.incomeLast([]).isEmpty)
    }
}
