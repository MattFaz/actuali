import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct ParseAndQueueTransactionIntentTests {

    private let appBundle = Bundle(identifier: "com.mfazz.ActualiOS")!

    @Test func formatsAmountWithLocaleAndTwoFractionalDigits() {
        let dialog = ParseAndQueueTransactionIntent.dialogText(
            amount: 12.5,
            payee: "Cafe",
            locale: Locale(identifier: "fr_FR"), bundle: appBundle)
        #expect(dialog == "12,50 chez Cafe a été mis en attente pour vérification")
    }

    @Test func formatsUnknownPayeeUsingTheRequestedLocale() {
        let dialog = ParseAndQueueTransactionIntent.dialogText(
            amount: nil,
            payee: nil,
            locale: Locale(identifier: "en_US"), bundle: appBundle)
        #expect(dialog == "Queued ? at Unknown for review")
    }
    private func makeOnDiskBudget() throws -> String {
        let budgetId = "test-parse-queue-\(UUID().uuidString)"
        let directory = BudgetFileManager.shared.budgetDirectory(for: budgetId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let queue = try DatabaseQueue(path: BudgetFileManager.shared.databasePath(for: budgetId).path)
        try queue.write { database in
            try database.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    type TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );
                """)
        }
        return budgetId
    }

    @Test func coldStartQueuesConfiguredBudgetIdentity() async throws {
        let budgetId = try makeOnDiskBudget()
        defer { try? BudgetFileManager.shared.deleteBudget(budgetId) }

        let budgetStore = BudgetStore.previewInstance()
        budgetStore.currentBudgetId = budgetId
        let pendingStore = PendingImportStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("pending-imports-\(UUID().uuidString).json")
        )

        let pending = try await ParseAndQueueTransactionIntent.queue(
            text: "Paid $12.50 at Cafe",
            store: budgetStore,
            pendingImportStore: pendingStore
        )

        #expect(pending.originBudgetId == budgetId)
        #expect(pendingStore.imports.count == 1)
    }

    @Test func readinessFailureIsSurfacedWithoutQueuing() async throws {
        let budgetStore = BudgetStore.previewInstance()
        budgetStore.currentBudgetId = "missing-\(UUID().uuidString)"
        let pendingStore = PendingImportStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("pending-imports-\(UUID().uuidString).json")
        )

        await #expect(throws: LogTransactionError.self) {
            try await ParseAndQueueTransactionIntent.queue(
                text: "Paid $12.50 at Cafe",
                store: budgetStore,
                pendingImportStore: pendingStore
            )
        }

        #expect(pendingStore.imports.isEmpty)
    }
}