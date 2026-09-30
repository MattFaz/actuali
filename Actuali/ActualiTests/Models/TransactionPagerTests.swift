import Foundation
import Synchronization
import Testing
@testable import Actuali

/// Pins TransactionPager, the paging state shared by the transaction lists
/// (GH #65): it fetches newest-first pages through an injected fetch closure,
/// tracks whether more pages exist, carries the active search into follow-up
/// pages, and ignores stale in-flight loads after a reset.
@MainActor
struct TransactionPagerTests {
    private func makeTxn(_ id: String) -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: 20_260_601,
            amount: -1000,
            payeeId: nil,
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    /// Pager over a fixed in-memory list, slicing like SQL LIMIT/OFFSET.
    private func makePager(over ids: [String], pageSize: Int = 3) -> TransactionPager {
        let all = ids.map(makeTxn)
        return TransactionPager(pageSize: pageSize) { offset, limit, search in
            let matching = search.map { s in all.filter { $0.id.contains(s) } } ?? all
            return Array(matching.dropFirst(offset).prefix(limit))
        }
    }

    @Test func firstPageFillsAndReportsMore() async {
        let pager = makePager(over: ["a", "b", "c", "d"])

        await pager.loadFirstPage()

        #expect(pager.transactions.map(\.id) == ["a", "b", "c"])
        #expect(pager.hasMore)
    }

    @Test func shortFirstPageReportsNoMore() async {
        let pager = makePager(over: ["a", "b"])

        await pager.loadFirstPage()

        #expect(pager.transactions.map(\.id) == ["a", "b"])
        #expect(!pager.hasMore)
    }

    @Test func nextPageAppendsAndStopsOnShortPage() async {
        let pager = makePager(over: ["a", "b", "c", "d"])

        await pager.loadFirstPage()
        await pager.loadNextPage()

        #expect(pager.transactions.map(\.id) == ["a", "b", "c", "d"])
        #expect(!pager.hasMore)

        // Exhausted — a further call must not refetch or duplicate.
        await pager.loadNextPage()
        #expect(pager.transactions.map(\.id) == ["a", "b", "c", "d"])
    }

    /// A page boundary exactly at the end: the follow-up page is empty and
    /// must flip hasMore without changing the list.
    @Test func exactMultipleEndsWithEmptyPage() async {
        let pager = makePager(over: ["a", "b", "c"])

        await pager.loadFirstPage()
        #expect(pager.hasMore)

        await pager.loadNextPage()
        #expect(pager.transactions.map(\.id) == ["a", "b", "c"])
        #expect(!pager.hasMore)
    }

    @Test func searchCarriesIntoFollowUpPages() async {
        let pager = makePager(over: ["x-1", "x-2", "x-3", "x-4", "y-1"])

        await pager.loadFirstPage(search: "x")
        #expect(pager.transactions.map(\.id) == ["x-1", "x-2", "x-3"])
        #expect(pager.hasMore)

        await pager.loadNextPage()
        #expect(pager.transactions.map(\.id) == ["x-1", "x-2", "x-3", "x-4"])
        #expect(!pager.hasMore)
    }

    @Test func newFirstPageReplacesSearchResults() async {
        let pager = makePager(over: ["x-1", "y-1"])

        await pager.loadFirstPage(search: "x")
        await pager.loadFirstPage(search: "y")

        #expect(pager.transactions.map(\.id) == ["y-1"])
    }

    /// A slow in-flight first-page load must not clobber a newer one that
    /// finished after it started (fast typing in the search field).
    @Test func staleFirstPageLoadIsDropped() async {
        let all = ["slow-1", "fast-1"].map(makeTxn)
        let slowStarted = Gate(), release = Gate()
        let pager = TransactionPager(pageSize: 3) { _, limit, search in
            if search == "slow" {
                slowStarted.open()
                await release.wait()
            }
            let matching = all.filter { $0.id.contains(search ?? "") }
            return Array(matching.prefix(limit))
        }

        async let slow: Void = pager.loadFirstPage(search: "slow")
        await slowStarted.wait()
        await pager.loadFirstPage(search: "fast")
        release.open()
        await slow

        #expect(pager.transactions.map(\.id) == ["fast-1"])
    }

    /// Concurrent load-more triggers (e.g. the sentinel row re-appearing
    /// during a scroll bounce) must not fetch or append the same page twice.
    @Test func concurrentNextPageLoadsOnlyOnce() async {
        let all = (1...6).map { "t-\($0)" }.map(makeTxn)
        let nextPageStarted = Gate(), release = Gate()
        // Only the first next-page fetch is held: a second one (the guard
        // failing) must run through and double-append, not deadlock.
        var nextPageFetches = 0
        let pager = TransactionPager(pageSize: 3) { offset, limit, _ in
            if offset > 0 {
                nextPageFetches += 1
                if nextPageFetches == 1 {
                    nextPageStarted.open()
                    await release.wait()
                }
            }
            return Array(all.dropFirst(offset).prefix(limit))
        }

        await pager.loadFirstPage()

        async let first: Void = pager.loadNextPage()
        await nextPageStarted.wait()
        await pager.loadNextPage()
        release.open()
        await first

        #expect(pager.transactions.map(\.id) == (1...6).map { "t-\($0)" })
    }

    /// A reset (new first page) while a next-page fetch is in flight must
    /// drop the stale append — it belongs to the old result set.
    @Test func staleNextPageIsDroppedAfterReset() async {
        let all = (1...6).map { "t-\($0)" }.map(makeTxn)
        let nextPageStarted = Gate(), release = Gate()
        let pager = TransactionPager(pageSize: 3) { offset, limit, search in
            if offset > 0 {
                nextPageStarted.open()
                await release.wait()
            }
            let matching = search.map { s in all.filter { $0.id.contains(s) } } ?? all
            return Array(matching.dropFirst(offset).prefix(limit))
        }

        await pager.loadFirstPage()

        async let next: Void = pager.loadNextPage()
        await nextPageStarted.wait()
        await pager.loadFirstPage(search: "t-1")
        release.open()
        await next

        #expect(pager.transactions.map(\.id) == ["t-1"])
    }
}
