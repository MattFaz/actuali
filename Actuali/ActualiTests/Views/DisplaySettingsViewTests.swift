import Foundation
import Testing
@testable import Actuali

struct DisplaySettingsViewTests {

    @Test func rejectsResultsFromStaleBudgetOrDatabase() {
        let oldDatabase = NSObject()
        let currentDatabase = NSObject()
        let oldRequest = DisplaySettingsLoadRequest(
            budgetID: "old-budget",
            databaseID: ObjectIdentifier(oldDatabase)
        )
        let currentRequest = DisplaySettingsLoadRequest(
            budgetID: "new-budget",
            databaseID: ObjectIdentifier(currentDatabase)
        )

        #expect(!DisplaySettingsView.shouldPublish(
            request: oldRequest,
            currentRequest: currentRequest,
            taskIsCancelled: false
        ))
    }

    @Test func publishesResultsForCurrentBudgetAndDatabase() {
        let database = NSObject()
        let request = DisplaySettingsLoadRequest(
            budgetID: "current-budget",
            databaseID: ObjectIdentifier(database)
        )

        #expect(DisplaySettingsView.shouldPublish(
            request: request,
            currentRequest: request,
            taskIsCancelled: false
        ))
    }
}