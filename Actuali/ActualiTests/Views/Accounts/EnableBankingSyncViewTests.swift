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

    // MARK: - BankAccountLinkView.linkableAccounts

    private func account(_ id: String, closed: Bool = false) -> Account {
        Account(id: id, name: id, type: .checking, offBudget: false, closed: closed, sortOrder: 0, balance: 0)
    }

    private func link(_ id: String, source: String, status: String? = "ok") -> BankSyncAccount {
        BankSyncAccount(
            id: id, name: id, externalAccountId: "ext-\(id)", syncSource: source,
            offBudget: false, closed: false, lastSync: Date(), status: status
        )
    }

    @Test func simpleFINRemoteKeepsTheOneFeedPerAccountRule() {
        let result = BankAccountLinkView.linkableAccounts(
            accounts: [account("free"), account("closed", closed: true), account("sf"), account("eb")],
            linked: [link("sf", source: "simpleFin"), link("eb", source: "enableBanking")],
            remoteSource: .simpleFin
        )
        #expect(result.map(\.id) == ["free"])
    }

    @Test func enableBankingRemoteListsStaleLinksThenFreeAccountsThenHealthyLinks() {
        let result = BankAccountLinkView.linkableAccounts(
            accounts: [account("free"), account("ok"), account("stale"), account("sf"), account("closed", closed: true)],
            linked: [
                link("ok", source: "enableBanking"),
                link("stale", source: "enableBanking", status: "reauth-required"),
                link("sf", source: "simpleFin"),
            ],
            remoteSource: .enableBanking
        )
        #expect(result.map(\.id) == ["stale", "free", "ok"])
    }

    @Test func onlyEnableBankingLinksAreMarkedAsReplaced() {
        let ids = BankAccountLinkView.enableBankingLinkedIds([
            link("ok", source: "enableBanking"),
            link("stale", source: "enableBanking", status: "reauth-required"),
            link("sf", source: "simpleFin"),
        ])
        #expect(ids == ["ok", "stale"])
    }
}
