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

    // MARK: - Bucketing Tests

    @Test func bucketsPutsUngroupedFirstFollowedByCustomGroupsInOrder() {
        let groupA = makeGroup(id: "g1", name: "Daily Banking", sortOrder: 1)
        let groupB = makeGroup(id: "g2", name: "Savings Goals", sortOrder: 2)

        let accUngrouped = makeAccount(id: "1", name: "Wallet")
        let accGroupA = makeAccount(id: "2", name: "Checking", groupId: "g1")
        let accGroupB = makeAccount(id: "3", name: "Emergency Fund", groupId: "g2")

        let buckets = AccountListBucket.buckets(
            for: [accGroupB, accUngrouped, accGroupA],
            groups: [groupA, groupB]
        )

        #expect(buckets.count == 3)
        #expect(buckets[0].id == "ungrouped")
        #expect(buckets[0].group == nil)
        #expect(buckets[0].accounts.map(\.id) == ["1"])

        #expect(buckets[1].id == "g1")
        #expect(buckets[1].group?.name == "Daily Banking")
        #expect(buckets[1].accounts.map(\.id) == ["2"])

        #expect(buckets[2].id == "g2")
        #expect(buckets[2].group?.name == "Savings Goals")
        #expect(buckets[2].accounts.map(\.id) == ["3"])
    }

    @Test func bucketsOmitsUngroupedWhenAllAccountsBelongToGroups() {
        let group = makeGroup(id: "g1", name: "Bank Accounts", sortOrder: 1)
        let acc = makeAccount(id: "1", name: "Checking", groupId: "g1")

        let buckets = AccountListBucket.buckets(for: [acc], groups: [group])

        #expect(buckets.count == 1)
        #expect(buckets[0].id == "g1")
        #expect(buckets[0].accounts.map(\.id) == ["1"])
    }

    @Test func bucketsTreatsAccountsWithUnknownGroupIdAsUngrouped() {
        let liveGroup = makeGroup(id: "g1", name: "Active Group", sortOrder: 1)
        let acc1 = makeAccount(id: "1", name: "Checking", groupId: "g1")
        let accOrphan = makeAccount(id: "2", name: "Old Group Account", groupId: "non-existent")

        let buckets = AccountListBucket.buckets(for: [acc1, accOrphan], groups: [liveGroup])

        #expect(buckets.count == 2)
        #expect(buckets[0].id == "ungrouped")
        #expect(buckets[0].accounts.map(\.id) == ["2"])
        #expect(buckets[1].id == "g1")
        #expect(buckets[1].accounts.map(\.id) == ["1"])
    }

    // MARK: - Search Filtering Tests

    @Test func filterReturnsAllAccountsWhenQueryIsEmpty() {
        let acc = makeAccount(id: "1", name: "Checking")
        let result = AccountPickerView.filterAccounts([acc], groups: [], matching: "  ")

        #expect(result.map(\.id) == ["1"])
    }

    @Test func filterMatchesAccountNameCaseInsensitively() {
        let checking = makeAccount(id: "1", name: "Chase Checking")
        let savings = makeAccount(id: "2", name: "Ally Savings")

        let result = AccountPickerView.filterAccounts([checking, savings], groups: [], matching: "chase")

        #expect(result.map(\.id) == ["1"])
    }

    @Test func filterMatchesGroupNameAndIncludesAllMembers() {
        let group = makeGroup(id: "g1", name: "Credit Cards")
        let card1 = makeAccount(id: "1", name: "Amex Platinum", groupId: "g1")
        let card2 = makeAccount(id: "2", name: "Sapphire Reserve", groupId: "g1")
        let checking = makeAccount(id: "3", name: "Checking", groupId: nil)

        let result = AccountPickerView.filterAccounts([card1, card2, checking], groups: [group], matching: "Credit")

        #expect(result.map(\.id) == ["1", "2"])
    }

    @Test func filterDropsAllAccountsWhenQueryDoesNotMatch() {
        let acc = makeAccount(id: "1", name: "Checking")
        let result = AccountPickerView.filterAccounts([acc], groups: [], matching: "Crypto")

        #expect(result.isEmpty)
    }
}
