import Foundation
import Testing
import UserNotifications
@testable import Actuali

struct CreditCardDueNotifierTests {

    private func makeDefaults(enabled: Bool) -> CreditCardNotificationSettings {
        let name = "CreditCardDueNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = CreditCardNotificationSettings(defaults: defaults)
        settings.isEnabled = enabled
        return settings
    }

    private func account(id: String, name: String, balance: Int, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .credit, offBudget: false, closed: closed, sortOrder: 0, balance: balance)
    }

    private func fixedCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test func disabledSettingRemovesPendingNotificationsAndSchedulesNothing() async {
        let center = FakeCreditCardNotificationCenter()
        let card = account(id: "card1", name: "Visa", balance: -5000)
        let cycle = CreditCardCycle(statementDay: 15)

        await CreditCardDueNotifier.scheduleNotifications(
            accounts: [card],
            cycles: ["card1": cycle],
            currencyCode: "USD",
            settings: makeDefaults(enabled: false),
            center: center
        )

        #expect(center.authorizationRequested == false)
        #expect(center.added.isEmpty)
        let expectedRemoved = [7, 5, 3, 1].map { CreditCardDueNotifier.requestIdentifier(accountId: "card1", offsetDays: $0) }
        #expect(center.removedIdentifiers == expectedRemoved)
    }

    @Test func paidCardSchedulesNothingAndCancelsPending() async {
        let center = FakeCreditCardNotificationCenter()
        let card = account(id: "card1", name: "Visa", balance: 0)
        let cycle = CreditCardCycle(statementDay: 15)

        await CreditCardDueNotifier.scheduleNotifications(
            accounts: [card],
            cycles: ["card1": cycle],
            currencyCode: "USD",
            settings: makeDefaults(enabled: true),
            center: center
        )

        #expect(center.authorizationRequested == true)
        #expect(center.added.isEmpty)
        let expectedCancelled = [7, 5, 3, 1].map { CreditCardDueNotifier.requestIdentifier(accountId: "card1", offsetDays: $0) }
        #expect(center.removedIdentifiers == expectedCancelled)
    }

    @Test func unpaidCardSchedulesRemindersForFutureOffsets() async {
        let cal = fixedCalendar()
        // Feb 20, 2026 at 08:00 UTC.
        // Cycle statement day 15, default 15d offset -> Statement Feb 15, due Mar 2, 2026.
        // Reminder dates:
        // 7d before: Feb 23 (future -> scheduled)
        // 5d before: Feb 25 (future -> scheduled)
        // 3d before: Feb 27 (future -> scheduled)
        // 1d before: Mar 1  (future -> scheduled)
        let now = cal.date(from: DateComponents(year: 2026, month: 2, day: 20, hour: 8, minute: 0))!
        let center = FakeCreditCardNotificationCenter()
        let card = account(id: "card1", name: "Visa", balance: -7500)
        let cycle = CreditCardCycle(statementDay: 15)

        await CreditCardDueNotifier.scheduleNotifications(
            accounts: [card],
            cycles: ["card1": cycle],
            currencyCode: "USD",
            settings: makeDefaults(enabled: true),
            center: center,
            now: now,
            calendar: cal
        )

        #expect(center.authorizationRequested == true)
        #expect(center.added.count == 4)

        let identifiers = Set(center.added.map(\.identifier))
        #expect(identifiers.contains(CreditCardDueNotifier.requestIdentifier(accountId: "card1", offsetDays: 7)))
        #expect(identifiers.contains(CreditCardDueNotifier.requestIdentifier(accountId: "card1", offsetDays: 5)))
        #expect(identifiers.contains(CreditCardDueNotifier.requestIdentifier(accountId: "card1", offsetDays: 3)))
        #expect(identifiers.contains(CreditCardDueNotifier.requestIdentifier(accountId: "card1", offsetDays: 1)))

        // Verify content
        let request1d = center.added.first(where: { $0.identifier.hasSuffix(".1d") })!
        #expect(request1d.content.title == "Visa payment due tomorrow")
        #expect(request1d.content.body.contains("75.00"))
        #expect(request1d.content.userInfo[CreditCardDueNotifier.accountIdKey] as? String == "card1")
        #expect(request1d.content.categoryIdentifier == CreditCardDueNotifier.categoryIdentifier)

        let request7d = center.added.first(where: { $0.identifier.hasSuffix(".7d") })!
        #expect(request7d.content.title == "Visa payment due in 7 days")
    }

    @Test func pastReminderDatesAreSkipped() async {
        let cal = fixedCalendar()
        // Feb 26, 2026 at 10:00 UTC.
        // Due date is Mar 2, 2026.
        // 7d before is Feb 23 09:00 -> in the past (skipped).
        // 5d before is Feb 25 09:00 -> in the past (skipped).
        // 3d before is Feb 27 09:00 -> future (scheduled).
        // 1d before is Mar 1 09:00 -> future (scheduled).
        let now = cal.date(from: DateComponents(year: 2026, month: 2, day: 26, hour: 10, minute: 0))!
        let center = FakeCreditCardNotificationCenter()
        let card = account(id: "card1", name: "Visa", balance: -5000)
        let cycle = CreditCardCycle(statementDay: 15)

        await CreditCardDueNotifier.scheduleNotifications(
            accounts: [card],
            cycles: ["card1": cycle],
            currencyCode: "USD",
            settings: makeDefaults(enabled: true),
            center: center,
            now: now,
            calendar: cal
        )

        let scheduledOffsets = center.added.map(\.identifier)
        #expect(scheduledOffsets.count == 2)
        #expect(scheduledOffsets.contains(CreditCardDueNotifier.requestIdentifier(accountId: "card1", offsetDays: 3)))
        #expect(scheduledOffsets.contains(CreditCardDueNotifier.requestIdentifier(accountId: "card1", offsetDays: 1)))
    }
}

private final class FakeCreditCardNotificationCenter: CreditCardNotificationCenter, @unchecked Sendable {
    var authorizationRequested = false
    var added: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequested = true
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}
