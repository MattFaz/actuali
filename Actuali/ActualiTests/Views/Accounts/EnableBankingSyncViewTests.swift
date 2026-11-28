import Foundation
import Testing
@testable import Actuali

struct EnableBankingSyncViewTests {
    @Test func readinessFollowsServerStatus() {
        #expect(EnableBankingSyncView.readiness(for: nil) == .unavailable)
        #expect(EnableBankingSyncView.readiness(for: false) == .notConfigured)
        #expect(EnableBankingSyncView.readiness(for: true) == .ready)
    }

    @Test func failedStatusCheckIsNotReportedAsAnOutdatedServer() {
        let offline = URLError(.notConnectedToInternet)
        #expect(EnableBankingSyncView.readiness(failure: offline) == .failed(offline.localizedDescription))
        #expect(EnableBankingSyncView.readiness(failure: offline) != .unavailable)
    }

    @Test func cancelledStatusCheckLeavesTheStateAlone() {
        #expect(EnableBankingSyncView.readiness(failure: CancellationError()) == nil)
        #expect(EnableBankingSyncView.readiness(failure: URLError(.cancelled)) == nil)
    }

    @Test func aCleanSyncReportsOnOneFooterLine() {
        let result = BudgetStore.BankSyncResult(added: 2, updated: 1)
        #expect(result.summary.contains("\n\n"))
        let line = EnableBankingSyncView.cleanSummary(of: result)
        #expect(line != nil)
        #expect(line?.contains("\n") == false)
        #expect(EnableBankingSyncView.cleanSummary(of: BudgetStore.BankSyncResult()) != nil)
    }

    @Test func aSyncWithProblemsLeavesTheReportingToTheAlert() {
        let result = BudgetStore.BankSyncResult(added: 1, problems: ["Bridge said: retry later"])
        #expect(EnableBankingSyncView.cleanSummary(of: result) == nil)
    }
}
