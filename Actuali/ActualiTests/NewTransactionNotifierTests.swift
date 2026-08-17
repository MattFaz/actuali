import Foundation
import Testing
import UserNotifications
@testable import Actuali

struct NewTransactionNotifierTests {

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    private func makeTransaction(id: String, payeeName: String? = nil,
                                 categoryId: String? = nil, amount: Int = -1250,
                                 transferId: String? = nil,
                                 transferAcct: String? = nil) -> Transaction {
        Transaction(id: id, accountId: "acct1", date: 20260707, amount: amount,
                    payeeId: nil, payeeName: payeeName, categoryId: categoryId,
                    categoryName: nil, notes: nil, cleared: false, reconciled: false,
                    transferId: transferId, isParent: false, parentId: nil, tombstone: false,
                    sortOrder: nil, importedPayee: nil, transferAcct: transferAcct)
    }

    @Test func noContentForEmptyBatch() {
        #expect(NewTransactionNotifier.makeContent(for: [], currencyCode: "USD") == nil)
    }

    @Test func singleTransactionShowsAmountAndPayee() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Starbucks", categoryId: "food")],
            currencyCode: "USD")

        #expect(content?.title == localized("New transaction"))
        #expect(content?.body.contains(
            CurrencyAmountFormat.string(cents: 1250, currencyCode: "USD", narrowSymbol: false)
        ) == true)
        #expect(content?.body.contains("Starbucks") == true)
        #expect(content?.body.contains(localized("Needs a category")) == false)
    }

    /// Expenses are negative cents; the notification line must carry that
    /// sign so outflows read distinctly from income (GH #258). Uses
    /// narrowSymbol like narrowSymbolDropsCurrencyPrefixFromLines above —
    /// locale-robust, since narrow presentation never carries the ISO prefix.
    @Test func expenseLineShowsNegativeAmount() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Starbucks", categoryId: "food", amount: -1250)],
            currencyCode: "USD", narrowSymbol: true)

        #expect(content?.body.contains("-$12.50") == true)
    }

    @Test func incomeLineShowsPositiveAmount() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Employer", categoryId: "income", amount: 1250)],
            currencyCode: "USD", narrowSymbol: true)

        #expect(content?.body.contains("-") == false)
        #expect(content?.body.contains("$12.50") == true)
    }

    @Test func singleUncategorizedTransactionAsksForCategory() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Starbucks")],
            currencyCode: "USD")

        #expect(content?.body.contains(localized("Needs a category")) == true)
    }

    /// A transfer between on-budget accounts can't take a category, so its
    /// line must not nag for one (GH #104).
    @Test func transferDoesNotAskForCategory() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Savings",
                                  transferId: "leg-2", transferAcct: "acct2")],
            currencyCode: "USD")

        #expect(content?.body.contains(localized("Needs a category")) == false)
    }

    /// Off-budget accounts aren't categorized at all (GH #123).
    @Test func offBudgetTransactionDoesNotAskForCategory() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Broker")],
            currencyCode: "USD", offBudgetAccountIds: ["acct1"])

        #expect(content?.body.contains(localized("Needs a category")) == false)
    }

    /// Money leaving the budget still needs a category: a transfer whose
    /// other side is off-budget keeps the marker (matches the Budget tab's
    /// uncategorized filter).
    @Test func transferToOffBudgetAccountStillAsksForCategory() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Brokerage",
                                  transferId: "leg-2", transferAcct: "acct2")],
            currencyCode: "USD", offBudgetAccountIds: ["acct2"])

        #expect(content?.body.contains(localized("Needs a category")) == true)
    }

    @Test func singleTransactionShowsAccountWhenKnown() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Starbucks", categoryId: "food")],
            currencyCode: "USD", accountNames: ["acct1": "Checking"])

        #expect(content?.body.contains(String(format: localized(" on %@"), "Checking")) == true)
    }

    /// Symbol Only (GH #83) reaches notification bodies too. Locale-robust:
    /// the narrow presentation never carries the ISO disambiguation prefix.
    @Test func narrowSymbolDropsCurrencyPrefixFromLines() {
        let content = NewTransactionNotifier.makeContent(
            for: [makeTransaction(id: "t1", payeeName: "Starbucks", categoryId: "food")],
            currencyCode: "NZD", narrowSymbol: true)

        #expect(content?.body.contains("NZ") == false)
        #expect(content?.body.contains("$") == true)
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

        #expect(content?.title == String(format: localized("%lld new transactions"), Int64(2)))
        let lines = content?.body.components(separatedBy: "\n")
        #expect(lines?.count == 2)
        #expect(lines?.first?.contains(
            CurrencyAmountFormat.string(cents: 500, currencyCode: "USD", narrowSymbol: false)
        ) == true)
        #expect(lines?.first?.contains("Starbucks") == true)
        #expect(lines?.first?.contains(String(format: localized(" on %@"), "Checking")) == true)
        #expect(lines?.first?.contains(localized("Needs a category")) == false)
        #expect(lines?.last?.contains(
            CurrencyAmountFormat.string(cents: 4200, currencyCode: "USD", narrowSymbol: false)
        ) == true)
        #expect(lines?.last?.contains("Shell") == true)
        #expect(lines?.last?.contains(localized("Needs a category")) == true)
        #expect(content?.userInfo[NewTransactionNotifier.transactionIdsKey] as? [String]
                == ["t1", "t2"])
    }

    /// Detail lines are capped so a big sync doesn't produce a wall of text;
    /// the overflow is summarized and tap-through still carries every id.
    @Test func longBatchCapsDetailLinesWithOverflowCount() {
        let batch = (1...6).map { makeTransaction(id: "t\($0)", categoryId: "food") }

        let content = NewTransactionNotifier.makeContent(for: batch, currencyCode: "USD")

        #expect(content?.title == String(format: localized("%lld new transactions"), Int64(6)))
        let lines = content?.body.components(separatedBy: "\n") ?? []
        #expect(lines.count == 5)
        #expect(lines.last?.contains(String(format: localized("…and %lld more"), Int64(2))) == true)
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
