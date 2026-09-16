import Foundation
import Testing
@testable import Actuali

/// The transaction status filter chips (GH #439) default to All with the
/// strip visible, persist their selection, and hide the strip without
/// stranding an active filter behind it.
///
/// The restore-on-launch half isn't covered here: `previewInstance()` is built
/// by an init that skips every UserDefaults read, and the real init does file
/// system work no unit test should trigger. Same gap as the other display
/// settings suites.
@MainActor
struct BudgetStoreTransactionStatusFilterTests {
    private let filterKey = "transactionStatusFilter"
    private let stripKey = "showTransactionStatusFilters"

    private func withSavedDefaults(_ body: () -> Void) {
        let savedFilter = UserDefaults.standard.object(forKey: filterKey)
        let savedStrip = UserDefaults.standard.object(forKey: stripKey)
        UserDefaults.standard.removeObject(forKey: filterKey)
        UserDefaults.standard.removeObject(forKey: stripKey)
        defer {
            if let savedFilter {
                UserDefaults.standard.set(savedFilter, forKey: filterKey)
            } else {
                UserDefaults.standard.removeObject(forKey: filterKey)
            }
            if let savedStrip {
                UserDefaults.standard.set(savedStrip, forKey: stripKey)
            } else {
                UserDefaults.standard.removeObject(forKey: stripKey)
            }
        }
        body()
    }

    @Test func defaultsToAllWithStripVisible() {
        withSavedDefaults {
            let store = BudgetStore.previewInstance()
            #expect(store.transactionStatusFilter == .all)
            #expect(store.showTransactionStatusFilters == true)
        }
    }

    @Test func selectionPersistsToUserDefaults() {
        withSavedDefaults {
            let store = BudgetStore.previewInstance()
            store.transactionStatusFilter = .uncategorized
            #expect(UserDefaults.standard.string(forKey: filterKey) == "uncategorized")
            store.transactionStatusFilter = .all
            #expect(UserDefaults.standard.string(forKey: filterKey) == "all")
        }
    }

    @Test func hidingTheStripResetsTheFilter() {
        withSavedDefaults {
            let store = BudgetStore.previewInstance()
            store.transactionStatusFilter = .reconciled
            store.showTransactionStatusFilters = false
            #expect(store.transactionStatusFilter == .all)
            #expect(UserDefaults.standard.string(forKey: filterKey) == "all")
            #expect(UserDefaults.standard.bool(forKey: stripKey) == false)
        }
    }

    @Test func rawValuesRoundTrip() {
        #expect(TransactionStatusFilter.allCases.map(\.rawValue)
            == ["all", "uncategorized", "uncleared", "cleared", "reconciled"])
        for filter in TransactionStatusFilter.allCases {
            #expect(TransactionStatusFilter(rawValue: filter.rawValue) == filter)
        }
        #expect(TransactionStatusFilter(rawValue: "wobbly") == nil)
    }

    /// The relaunch restore path (`init` reads UserDefaults through
    /// `resolved(from:)`, the same seam as BudgetDisplayStyle): a saved
    /// value comes back, and a value written by a future build falls back
    /// to All instead of crashing or stranding the list.
    @Test func savedValueRestoresAndUnknownFallsBackToAll() {
        for filter in TransactionStatusFilter.allCases {
            #expect(TransactionStatusFilter.resolved(from: filter.rawValue) == filter)
        }
        #expect(TransactionStatusFilter.resolved(from: nil) == .all)
        #expect(TransactionStatusFilter.resolved(from: "wobbly") == .all)
    }
}