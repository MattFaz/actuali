import Foundation
import Testing
@testable import Actuali

struct DisplaySettingsViewTests {

    private let appBundle = Bundle(identifier: "com.mfazz.ActualiOS")!

    @Test func settingsLabelsUseRequestedLocale() {
        let locale = Locale(identifier: "fr_FR")

        #expect(AppearanceMode.system.label(locale: locale, bundle: appBundle) == "Système")
        #expect(StartTab.accounts.label(locale: locale, bundle: appBundle) == "Comptes")
        #expect(TransactionDisplayMode.flat.label(locale: locale, bundle: appBundle) == "Liste simple")
        #expect(UncategorizedTapAction.categoryPicker.label(locale: locale, bundle: appBundle) == "Sélecteur de catégories")
    }

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