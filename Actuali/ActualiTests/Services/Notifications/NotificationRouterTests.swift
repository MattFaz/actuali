import Foundation
import Testing
@testable import Actuali

@MainActor
struct NotificationRouterTests {
    // MARK: - Route parsing (tapped notification -> route)

    @Test func singleTransactionIdRoutesToEditor() {
        let route = NotificationRouter.route(
            categoryIdentifier: NewTransactionNotifier.categoryIdentifier,
            userInfo: [NewTransactionNotifier.transactionIdsKey: ["t1"]]
        )

        #expect(route == .editTransaction(id: "t1"))
    }

    @Test func multipleTransactionIdsRouteToUncategorized() {
        let route = NotificationRouter.route(
            categoryIdentifier: NewTransactionNotifier.categoryIdentifier,
            userInfo: [NewTransactionNotifier.transactionIdsKey: ["t1", "t2"]]
        )

        #expect(route == .uncategorized)
    }

    @Test func missingIdsRouteToUncategorized() {
        let route = NotificationRouter.route(
            categoryIdentifier: NewTransactionNotifier.categoryIdentifier,
            userInfo: [:]
        )

        #expect(route == .uncategorized)
    }

    @Test func unrelatedNotificationCategoryIsIgnored() {
        let route = NotificationRouter.route(
            categoryIdentifier: "SOMETHING_ELSE",
            userInfo: [NewTransactionNotifier.transactionIdsKey: ["t1"]]
        )

        #expect(route == nil)
    }

    // MARK: - Destination resolution (route -> screen)

    private func makeStore() async throws -> BudgetStore {
        let (database, _) = try await makeTestDatabase(TestSchema.core + [
            "INSERT INTO transactions (id, acct, amount, date) VALUES ('t1', 'acct1', -1250, 20260707)",
        ])
        return try await makeTestStore(database: database)
    }

    @Test func resolvesEditorForExistingTransaction() async throws {
        let store = try await makeStore()

        let destination = await NotificationRouter.destination(
            for: .editTransaction(id: "t1"), in: store
        )

        guard case .editor(let transaction) = destination else {
            Issue.record("Expected .editor, got \(destination)")
            return
        }
        #expect(transaction.id == "t1")
    }

    @Test func staleTransactionIdFallsBackToUncategorized() async throws {
        let store = try await makeStore()

        let destination = await NotificationRouter.destination(
            for: .editTransaction(id: "gone"), in: store
        )

        #expect(destination == .uncategorized)
    }

    @Test func uncategorizedRouteResolvesDirectly() async throws {
        let store = try await makeStore()

        let destination = await NotificationRouter.destination(
            for: .uncategorized, in: store
        )

        #expect(destination == .uncategorized)
    }
}
