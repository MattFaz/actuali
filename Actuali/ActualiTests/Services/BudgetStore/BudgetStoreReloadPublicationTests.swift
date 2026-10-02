import Combine
import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreReloadPublicationTests {
    @Test func unchangedRefreshPublishesOnlyDataVersionAndChangedValuesStillPublish() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core + [TestSchema.preferences, TestSchema.tags, """
        INSERT INTO accounts (id, name, type, sort_order) VALUES ('a', 'Checking', 'checking', 1);
        INSERT INTO category_groups (id, name, sort_order) VALUES ('g', 'Expenses', 1);
        INSERT INTO categories (id, name, cat_group, sort_order) VALUES ('c', 'Food', 'g', 1);
        INSERT INTO transactions (id, acct, amount, date, cleared, sort_order) VALUES ('t', 'a', -500, 20261001, 0, 1);
        INSERT INTO preferences (id, value) VALUES ('defaultCurrencyCode', 'USD'), ('numberFormat', 'comma-dot');
        """])
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        store.widgetSnapshotStore = nil
        await store.fetchBudgetMonth(BudgetView.currentMonthString())
        await store.sync()
        #expect(store.error == nil)
        var counts: [String: Int] = [:]
        func watch(_ publisher: Published<some Any>.Publisher, _ name: String) -> AnyCancellable {
            publisher.dropFirst().sink { _ in counts[name, default: 0] += 1 }
        }
        let subscriptions = [
            watch(store.$accounts, "accounts"), watch(store.$transactions, "transactions"),
            watch(store.$uncategorizedCount, "uncategorizedCount"), watch(store.$categoryGroups, "categoryGroups"),
            watch(store.$payees, "payees"), watch(store.$tags, "tags"), watch(store.$tagSummaries, "tagSummaries"),
            watch(store.$currentBudgetMonth, "currentBudgetMonth"), watch(store.$schedules, "schedules"),
            watch(store.$scheduleStatuses, "scheduleStatuses"), watch(store.$schedulePaymentDates, "schedulePaymentDates"),
            watch(store.$creditCardStatementDues, "creditCardStatementDues"), watch(store.$bankSyncAccounts, "bankSyncAccounts"),
            watch(store.$creditCardConfigs, "creditCardConfigs"), watch(store.$loanConfigs, "loanConfigs"),
            watch(store.$depositConfigs, "depositConfigs"), watch(store.$cardAccountMappings, "cardAccountMappings"),
            watch(store.$upcomingScheduledTransactionLength, "upcomingScheduledTransactionLength"),
            watch(store.$goalTemplatesEnabled, "goalTemplatesEnabled"), watch(store.$goalTemplatesUIEnabled, "goalTemplatesUIEnabled"),
            watch(store.$currencyCode, "currencyCode"), watch(store.$numberFormat, "numberFormat"),
            watch(store.$dataVersion, "dataVersion"),
        ]
        defer { subscriptions.forEach { $0.cancel() } }
        await store.sync()
        #expect(store.error == nil)
        #expect(counts == ["dataVersion": 1])

        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "UPDATE transactions SET amount = -750, category = 'c' WHERE id = 't'")
            try db.execute(sql: "UPDATE categories SET name = 'Groceries' WHERE id = 'c'")
            try db.execute(sql: "UPDATE preferences SET value = 'EUR' WHERE id = 'defaultCurrencyCode'")
            try db.execute(sql: "UPDATE preferences SET value = 'dot-comma' WHERE id = 'numberFormat'")
        }
        store.bankSyncAccountsFetchedForTesting = {
            // The final read still sees the previous published snapshot.
            #expect(counts == ["dataVersion": 1])
            #expect(store.accounts.first?.balance == -500)
        }
        await store.sync()
        store.bankSyncAccountsFetchedForTesting = nil
        #expect(store.error == nil)
        #expect(store.accounts.first?.balance == -750)
        #expect(store.transactions.first?.categoryId == "c")
        #expect(store.uncategorizedCount == 0)
        #expect(store.categoryGroups.first?.categories.first?.name == "Groceries")
        #expect(store.currencyCode == "EUR")
        #expect(store.numberFormat == .dotComma)
        for name in ["accounts", "transactions", "uncategorizedCount", "categoryGroups", "currentBudgetMonth", "currencyCode", "numberFormat"] {
            #expect(counts[name] == 1)
        }
        #expect(counts["dataVersion"] == 2)
    }

    @Test func refreshSkipsUnchangedWidgetFileAndWritesRealChanges() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core + [TestSchema.preferences, """
        INSERT INTO category_groups (id, name, sort_order) VALUES ('g', 'Expenses', 1);
        INSERT INTO categories (id, name, cat_group, sort_order) VALUES ('c', 'Food', 'g', 1);
        INSERT INTO preferences (id, value) VALUES ('defaultCurrencyCode', 'USD'), ('numberFormat', 'comma-dot');
        """])
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotStore = WidgetSnapshotStore(containerURL: directory)
        store.widgetSnapshotStore = snapshotStore
        await store.sync()
        #expect(store.error == nil)
        let original = try Data(contentsOf: snapshotStore.fileURL)
        let marker = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: snapshotStore.fileURL.path)
        await store.sync()
        #expect(try Data(contentsOf: snapshotStore.fileURL) == original)
        #expect(try snapshotStore.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == marker)
        try await DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "UPDATE categories SET name = 'Groceries' WHERE id = 'c'")
            try db.execute(sql: "UPDATE preferences SET value = 'EUR' WHERE id = 'defaultCurrencyCode'")
            try db.execute(sql: "UPDATE preferences SET value = 'dot-comma' WHERE id = 'numberFormat'")
        }
        await store.sync()
        #expect(store.error == nil)
        #expect(try Data(contentsOf: snapshotStore.fileURL) != original)
        #expect(snapshotStore.read()?.categories.first?.name == "Groceries")
        #expect(snapshotStore.read()?.categories.first?.formattedAvailable == store.displayBalance(0))
        store.clearWidgetSnapshot()
        #expect(snapshotStore.read() == nil)
        store.publishWidgetSnapshot()
        #expect(snapshotStore.read() != nil)
    }

    @Test func failedWidgetWriteRetriesAndChangingDestinationWritesAgain() throws {
        let store = BudgetStore.previewInstance()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotStore = WidgetSnapshotStore(containerURL: directory)
        store.widgetSnapshotStore = snapshotStore
        store.widgetBudgetMonth = BudgetMonth(month: "2026-10", categoryBudgets: [])
        store.publishWidgetSnapshot()
        #expect(snapshotStore.read() == nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store.publishWidgetSnapshot()
        #expect(snapshotStore.read()?.month == "2026-10")
        let secondDirectory = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let secondStore = WidgetSnapshotStore(containerURL: secondDirectory)
        store.widgetSnapshotStore = secondStore
        store.publishWidgetSnapshot()
        #expect(secondStore.read()?.month == "2026-10")
    }
}
