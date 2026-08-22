import AppIntents
import Testing
@testable import Actuali

struct LogTransactionIntentTests {

    @Test func silentByDefaultSoAutomationsDoNotShowADialog() {
        let result = LogTransactionIntent.result(dialogText: "Logged $4.50 at Blue Bottle", showConfirmation: false)
        #expect(result.dialog == nil)
    }

    @Test func speaksWhenTheCallerAsksFor() {
        let result = LogTransactionIntent.result(dialogText: "Logged $4.50 at Blue Bottle", showConfirmation: true)
        #expect(result.dialog != nil)
    }

    @Test func siriShortcutOptsIntoTheSpokenConfirmation() {
        #expect(LogTransactionIntent(showConfirmation: true).showConfirmation)
        #expect(LogTransactionIntent().showConfirmation == false)
    }
}
