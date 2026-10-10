import BackgroundTasks
import Foundation
import Testing
@testable import Actuali

struct WalletDeliveryTests {
    private struct SubmitFailed: Error {}

    private func makeDelivery() throws -> (WalletDelivery, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalletDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (WalletDelivery(containerURL: dir), dir)
    }

    /// The extension can only ask for the app's own refresh task — iOS rejects
    /// identifiers the app doesn't permit — and it asks for no start delay.
    @Test func aDeliveryAsksForTheAppsRefreshWithNoDelay() throws {
        let (delivery, dir) = try makeDelivery()
        defer { try? FileManager.default.removeItem(at: dir) }
        var submitted: [BGTaskRequest] = []
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        delivery.requestRefresh(now: now) { submitted.append($0) }

        let request = try #require(submitted.first)
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        #expect(submitted.count == 1)
        #expect(request is BGAppRefreshTaskRequest)
        #expect(permitted?.contains(request.identifier) == true)
        #expect(request.earliestBeginDate == nil)
        #expect(delivery.status() == WalletDelivery.Status(lastDelivery: now))
    }

    /// iOS may refuse the request (Background App Refresh off, or an extension
    /// type that can't schedule). The delivery is still recorded and the
    /// failure kept for Settings; a later success clears it.
    @Test func aRefusedRequestIsRecordedAndClearedByTheNextSuccess() throws {
        let (delivery, dir) = try makeDelivery()
        defer { try? FileManager.default.removeItem(at: dir) }

        delivery.requestRefresh(now: Date(timeIntervalSince1970: 1)) { _ in throw SubmitFailed() }

        #expect(delivery.status().lastDelivery == Date(timeIntervalSince1970: 1))
        #expect(delivery.status().lastRequestError != nil)

        delivery.requestRefresh(now: Date(timeIntervalSince1970: 2)) { _ in }

        #expect(delivery.status() == WalletDelivery.Status(lastDelivery: Date(timeIntervalSince1970: 2)))
    }
}
