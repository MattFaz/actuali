import Foundation
import Observation

/// Paging state for the transaction lists (GH #65): loads newest-first pages
/// through an injected fetch (SQL LIMIT/OFFSET underneath), remembers the
/// active search so follow-up pages stay filtered, and tracks whether another
/// page may exist so views know when to show a load-more sentinel.
@MainActor
@Observable
final class TransactionPager {
    typealias FetchPage = (_ offset: Int, _ limit: Int, _ search: String?) async -> [Transaction]

    private(set) var transactions: [Transaction] = []
    private(set) var hasMore = false

    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let fetchPage: FetchPage
    @ObservationIgnored private var search: String?
    @ObservationIgnored private var isLoadingMore = false
    /// Bumped on every reset; loads capture it before fetching and drop
    /// their result if a newer first page started meanwhile (fast typing in
    /// the search field, refresh racing a scroll-triggered page load).
    @ObservationIgnored private var generation = 0

    init(pageSize: Int = BudgetDatabase.transactionPageSize, fetchPage: @escaping FetchPage) {
        self.pageSize = pageSize
        self.fetchPage = fetchPage
    }

    /// Replace the list with the first page for `search` (nil = no filter).
    func loadFirstPage(search: String? = nil) async {
        self.search = search
        generation += 1
        let started = generation
        let page = await fetchPage(0, pageSize, search)
        guard started == generation else { return }
        transactions = page
        hasMore = page.count >= pageSize
    }

    /// Append the next page of the current result set, if one may exist.
    func loadNextPage() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let started = generation
        let page = await fetchPage(transactions.count, pageSize, search)
        guard started == generation else { return }
        transactions.append(contentsOf: page)
        hasMore = page.count >= pageSize
    }
}
