import Foundation
import Testing
import UserNotifications
@testable import Actuali

struct NewTransactionNotifierTests {

    private func makeTransaction(id: String, payeeName: String? = nil,
                                 categoryId: String? = nil, amount: Int = -1250) -> Transaction {
        Transaction(id: id, accountId: "acct1", date: 20260707, amount: amount,
                    payeeId: nil, payeeName: payeeName, categoryId: categoryId,
                    categoryName: nil, notes: nil, cleared: false, reconciled: false,
                    transferId: nil, isParent: false, parentId: nil, tombstone: false,
                    sortOrder: nil, importedPayee: nil)
    }

    @Test func noContentForEmptyBatch() {
        #expect(NewTransactionNotifier.makeContent(for: [], currencyCode: "USD") == nil)
    }

    @Test func singleTransactionShowsAmountAndPayee() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Starbucks", categoryId: "food")],
            currencyCode: "USD")

        #expect(content?.title == "New transaction")
        #expect(content?.body.contains("12.50") == true)
        #expect(content?.body.contains("Starbucks") == true)
        #expect(content?.body.localizedCaseInsensitiveContains("category") == false)
    }

    @Test func singleUncategorizedTransactionAsksForCategory() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Starbucks")],
            currencyCode: "USD")

        #expect(content?.body.localizedCaseInsensitiveContains("needs a category") == true)
    }

    @Test func singleTransactionShowsAccountWhenKnown() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Starbucks", categoryId: "food")],
            currencyCode: "USD", accountNames: ["acct1": "Checking"])

        #expect(content?.body.contains("on Checking") == true)
    }

    /// A batch shows one detail line per transaction — amount, payee,
    /// account — with uncategorized ones flagged individually.
    @Test func multipleTransactionsListDetailLines() {
        let batch = [
            makeTransaction(id: "t1", payeeName: "Starbucks", categoryId: "food", amount: -500),
            makeTransaction(id: "t2", payeeName: "Shell", amount: -4200),
        ]

        let content = NewTransactionNotifier.makeContent(
            for: batch, currencyCode: "USD", accountNames: ["acct1": "Checking"])

        #expect(content?.title == "2 new transactions")
        let lines = content?.body.components(separatedBy: "\n")
        #expect(lines?.count == 2)
        #expect(lines?.first?.contains("5.00") == true)
        #expect(lines?.first?.contains("Starbucks") == true)
        #expect(lines?.first?.contains("on Checking") == true)
        #expect(lines?.first?.localizedCaseInsensitiveContains("category") == false)
        #expect(lines?.last?.contains("42.00") == true)
        #expect(lines?.last?.contains("Shell") == true)
        #expect(lines?.last?.localizedCaseInsensitiveContains("needs a category") == true)
        #expect(content?.userInfo[NewTransactionNotifier.transactionIdsKey] as? [String]
                == ["t1", "t2"])
    }

    /// Detail lines are capped so a big sync doesn't produce a wall of text;
    /// the overflow is summarized and tap-through still carries every id.
    @Test func longBatchCapsDetailLinesWithOverflowCount() {
        let batch = (1...6).map { makeTransaction(id: "t\($0)", categoryId: "food") }

        let content = NewTransactionNotifier.makeContent(for: batch, currencyCode: "USD")

        #expect(content?.title == "6 new transactions")
        let lines = content?.body.components(separatedBy: "\n") ?? []
        #expect(lines.count == 5)
        #expect(lines.last?.contains("2 more") == true)
        #expect((content?.userInfo[NewTransactionNotifier.transactionIdsKey] as? [String])?.count == 6)
    }

    @Test func contentCarriesRoutingMetadata() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1")], currencyCode: "USD")

        #expect(content?.userInfo[NewTransactionNotifier.transactionIdsKey] as? [String] == ["t1"])
        #expect(content?.categoryIdentifier == NewTransactionNotifier.categoryIdentifier)
        #expect(content?.threadIdentifier.isEmpty == false)
    }

    /// A stable request identifier makes a newer summary replace the previous
    /// one instead of stacking up in Notification Center.
    @Test func requestIdentifierIsStableAcrossBatches() {
        let first = NewTransactionNotifier.makeRequest(
            for: [makeTransaction(id: "t1")], currencyCode: "USD")
        let second = NewTransactionNotifier.makeRequest(
            for: [makeTransaction(id: "t2")], currencyCode: "USD")

        #expect(first?.identifier != nil)
        #expect(first?.identifier == second?.identifier)
    }

    private func makeSettings(enabled: Bool) -> TransactionNotificationSettings {
        let name = "NewTransactionNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = TransactionNotificationSettings(defaults: defaults)
        settings.isEnabled = enabled
        return settings
    }

    /// Background refresh always runs (fresh data on open); the opt-in only
    /// gates the notification itself. Opted out, notify must not touch
    /// Notification Center at all — not even to ask for permission.
    @Test func notifyPostsNothingWhenNotificationsDisabled() async {
        let center = NotificationCenterSpy()

        await NewTransactionNotifier.notify(
            about: [makeTransaction(id: "t1")], currencyCode: "USD",
            settings: makeSettings(enabled: false), center: center)

        #expect(center.authorizationRequested == false)
        #expect(center.added.isEmpty)
    }

    @Test func notifyPostsWhenNotificationsEnabled() async {
        let center = NotificationCenterSpy()

        await NewTransactionNotifier.notify(
            about: [makeTransaction(id: "t1")], currencyCode: "USD",
            settings: makeSettings(enabled: true), center: center)

        #expect(center.added.map(\.identifier) == [NewTransactionNotifier.requestIdentifier])
    }
}

private final class NotificationCenterSpy: NotificationPosting {
    var authorizationRequested = false
    var added: [UNNotificationRequest] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequested = true
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
    }
}
