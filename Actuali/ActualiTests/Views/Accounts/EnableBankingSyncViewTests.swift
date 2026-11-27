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

    @Test func banksLoadOnlyWhenTheCountryChangedOrNothingIsLoaded() {
        #expect(EnableBankingSyncView.needsBankLoad(country: "NL", loadedCountry: nil))
        #expect(EnableBankingSyncView.needsBankLoad(country: "DE", loadedCountry: "NL"))
        #expect(!EnableBankingSyncView.needsBankLoad(country: "NL", loadedCountry: "NL"))
    }

    @Test func onlyAClosedSheetLeavesTheWaitRunning() {
        #expect(EnableBankingSyncView.isSheetClosed(OpenIDAuthError.cancelled))
        #expect(!EnableBankingSyncView.isSheetClosed(OpenIDAuthError.sessionFailed(URLError(.badURL))))
        #expect(!EnableBankingSyncView.isSheetClosed(OpenIDAuthError.noWindow))
        #expect(!EnableBankingSyncView.isSheetClosed(OpenIDAuthError.missingToken))
        #expect(!EnableBankingSyncView.isSheetClosed(URLError(.cancelled)))
    }

    @Test func noAccountsMessageOnlyForAnEmptyAuthorization() {
        let remote = BankSyncRemoteAccount(
            id: "r", name: "Current", institutionId: "i", institutionName: "Bank", balanceCents: nil, source: .enableBanking
        )
        #expect(EnableBankingSyncView.noAccountsMessage(for: []) != nil)
        #expect(EnableBankingSyncView.noAccountsMessage(for: [remote]) == nil)
    }

    @Test func defaultCountryUsesListedRegionElseFallback() {
        #expect(EnableBankingSyncView.defaultCountry(region: "DE") == "DE")
        #expect(EnableBankingSyncView.defaultCountry(region: "US") == "NL")
        #expect(EnableBankingSyncView.defaultCountry(region: nil) == "NL")
    }

    @Test func psuTypeOnlyFollowsTheChoiceWhenBothAreOffered() {
        func bank(_ types: [String]?) -> EnableBankingBank {
            EnableBankingBank(name: "B", country: "NL", psuTypes: types, beta: nil, maximumConsentValidity: nil)
        }
        #expect(EnableBankingSyncView.psuType(for: bank(["personal", "business"]), choice: "business") == "business")
        #expect(EnableBankingSyncView.psuType(for: bank(["business"]), choice: "personal") == "business")
        #expect(EnableBankingSyncView.psuType(for: bank(nil), choice: "personal") == "personal")
    }

    @Test func aLinkedAccountsBankIsFoundByTrimmedCaseInsensitiveName() {
        func bank(_ name: String) -> EnableBankingBank {
            EnableBankingBank(name: name, country: "NL", psuTypes: nil, beta: nil, maximumConsentValidity: nil)
        }
        let abn = bank("ABN AMRO")
        let ing = bank("ING")
        #expect(EnableBankingSyncView.bank(named: "ING", in: [abn, ing]) == ing)
        #expect(EnableBankingSyncView.bank(named: "  abn amro\n", in: [abn, ing]) == abn)
        #expect(EnableBankingSyncView.bank(named: "Rabobank", in: [abn, ing]) == nil)
        #expect(EnableBankingSyncView.bank(named: nil, in: [abn, ing]) == nil)
        #expect(EnableBankingSyncView.bank(named: "ING", in: []) == nil)
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
