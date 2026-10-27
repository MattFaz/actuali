import Testing
@testable import Actuali

struct AccountPickerViewTests {
    private func makeAccount(
        id: String,
        name: String,
        offBudget: Bool = false,
        closed: Bool = false,
        sortOrder: Int = 0,
        groupId: String? = nil,
        balance: Int = 0
    ) -> Account {
        Account(
            id: id,
            name: name,
            type: .checking,
            offBudget: offBudget,
            closed: closed,
            sortOrder: sortOrder,
            groupId: groupId,
            balance: balance
        )
    }

    private func makeGroup(
        id: String,
        name: String,
        sortOrder: Double = 0,
        tombstone: Bool = false
    ) -> AccountGroup {
        AccountGroup(
            id: id,
            name: name,
            sortOrder: sortOrder,
            tombstone: tombstone
        )
    }

    // MARK: - Grouping Tests

    @Test func groupsIntoOnBudgetAndOffBudgetWhenNoCustomGroupsExist() {
        let checking = makeAccount(id: "1", name: "Checking", offBudget: false)
        let savings = makeAccount(id: "2", name: "Savings", offBudget: false)
        let investment = makeAccount(id: "3", name: "Brokerage", offBudget: true)

        let sections = AccountPickerView.groupAccounts([checking, savings, investment], groups: [])

        #expect(sections.count == 2)
        #expect(sections[0].id == "on-budget")
        #expect(sections[0].accounts.map(\.id) == ["1", "2"])
        #expect(sections[1].id == "off-budget")
        #expect(sections[1].accounts.map(\.id) == ["3"])
    }

    @Test func omitsEmptyBudgetSectionWhenNoAccountsMatch() {
        let checking = makeAccount(id: "1", name: "Checking", offBudget: false)

        let sections = AccountPickerView.groupAccounts([checking], groups: [])

        #expect(sections.count == 1)
        #expect(sections[0].id == "on-budget")
        #expect(sections[0].accounts.map(\.id) == ["1"])
    }

    @Test func groupsAccountsByCustomGroupsInOrder() {
        let groupA = makeGroup(id: "g1", name: "Daily Banking", sortOrder: 1)
        let groupB = makeGroup(id: "g2", name: "Credit Cards", sortOrder: 2)

        let checking = makeAccount(id: "1", name: "Checking", groupId: "g1")
        let card = makeAccount(id: "2", name: "Visa", groupId: "g2")
        let ungroupedOn = makeAccount(id: "3", name: "Other On", offBudget: false)
        let ungroupedOff = makeAccount(id: "4", name: "Other Off", offBudget: true)

        let sections = AccountPickerView.groupAccounts(
            [checking, card, ungroupedOn, ungroupedOff],
            groups: [groupB, groupA] // Out of order input to test sortOrder
        )

        #expect(sections.map(\.id) == ["g1", "g2", "on-budget", "off-budget"])
        #expect(sections[0].accounts.map(\.id) == ["1"])
        #expect(sections[1].accounts.map(\.id) == ["2"])
        #expect(sections[2].accounts.map(\.id) == ["3"])
        #expect(sections[3].accounts.map(\.id) == ["4"])
    }

    @Test func tombstonedGroupsAreIgnoredAndAccountsTreatedAsUngrouped() {
        let liveGroup = makeGroup(id: "g1", name: "Active Group", sortOrder: 1)
        let deadGroup = makeGroup(id: "g2", name: "Deleted Group", sortOrder: 2, tombstone: true)

        let acc1 = makeAccount(id: "1", name: "Checking", groupId: "g1")
        let acc2 = makeAccount(id: "2", name: "Old Acc", offBudget: false, groupId: "g2")

        let sections = AccountPickerView.groupAccounts([acc1, acc2], groups: [liveGroup, deadGroup])

        #expect(sections.map(\.id) == ["g1", "on-budget"])
        #expect(sections[0].accounts.map(\.id) == ["1"])
        #expect(sections[1].accounts.map(\.id) == ["2"])
    }

    // MARK: - Filtering Tests

    @Test func filterReturnsAllSectionsWhenQueryIsEmpty() {
        let acc = makeAccount(id: "1", name: "Checking")
        let section = AccountPickerSection(id: "on-budget", title: "On Budget", accounts: [acc])

        let result = AccountPickerView.filterSections([section], matching: "")

        #expect(result == [section])
    }

    @Test func filterMatchesAccountNameCaseInsensitively() {
        let checking = makeAccount(id: "1", name: "Chase Checking")
        let savings = makeAccount(id: "2", name: "Ally Savings")
        let section = AccountPickerSection(id: "on-budget", title: "On Budget", accounts: [checking, savings])

        let result = AccountPickerView.filterSections([section], matching: "chase")

        #expect(result.count == 1)
        #expect(result[0].accounts.map(\.id) == ["1"])
    }

    @Test func filterMatchesGroupTitleAndIncludesAllGroupAccounts() {
        let card1 = makeAccount(id: "1", name: "Amex")
        let card2 = makeAccount(id: "2", name: "Visa")
        let section = AccountPickerSection(id: "g1", title: "Credit Cards", accounts: [card1, card2])

        let result = AccountPickerView.filterSections([section], matching: "Credit")

        #expect(result.count == 1)
        #expect(result[0].accounts.map(\.id) == ["1", "2"])
    }

    @Test func filterDropsSectionsWithNoMatchingAccounts() {
        let acc = makeAccount(id: "1", name: "Checking")
        let section = AccountPickerSection(id: "on-budget", title: "On Budget", accounts: [acc])

        let result = AccountPickerView.filterSections([section], matching: "Nonexistent")

        #expect(result.isEmpty)
    }
}
