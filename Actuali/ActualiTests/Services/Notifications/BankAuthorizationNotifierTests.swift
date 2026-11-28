import Foundation
import Testing
import UserNotifications
@testable import Actuali

@MainActor
struct BankAuthorizationNotifierTests {
    @Test func postsTheBannerWhereNotificationsAreAllowed() async {
        let center = BankAuthorizationCenterSpy(status: .authorized)

        await BankAuthorizationNotifier.notifyApproved(center: center)

        #expect(center.added.map(\.identifier) == [BankAuthorizationNotifier.requestIdentifier])
        #expect(center.added.first?.content.title.isEmpty == false)
        #expect(center.added.first?.content.body.isEmpty == false)
        // Delivered at once: the person is waiting on another app's page.
        #expect(center.added.first?.trigger == nil)
    }

    @Test(arguments: [UNAuthorizationStatus.notDetermined, .denied, .provisional])
    func staysSilentAndNeverAsksWithoutPermission(status: UNAuthorizationStatus) async {
        let center = BankAuthorizationCenterSpy(status: status)

        await BankAuthorizationNotifier.notifyApproved(center: center)

        #expect(center.added.isEmpty)
        #expect(!center.authorizationRequested)
    }
}

private final class BankAuthorizationCenterSpy: NotificationPosting, @unchecked Sendable {
    let status: UNAuthorizationStatus
    var authorizationRequested = false
    var added: [UNNotificationRequest] = []

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequested = true
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}
