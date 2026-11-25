import Foundation
import Testing
@testable import Actuali

struct EnableBankingSyncViewTests {
    @Test func readinessFollowsServerStatus() {
        #expect(EnableBankingSyncView.readiness(for: nil) == .unavailable)
        #expect(EnableBankingSyncView.readiness(for: false) == .notConfigured)
        #expect(EnableBankingSyncView.readiness(for: true) == .ready)
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

    @Test func accountsNeedingSyncPicksNewAndBrokenEnableBankingLinks() {
        func link(_ id: String, source: String = "enableBanking", closed: Bool = false,
                  lastSync: Date? = Date(), status: String? = "ok") -> BankSyncAccount {
            BankSyncAccount(
                id: id, name: id, externalAccountId: "ext-\(id)", syncSource: source,
                offBudget: false, closed: closed, lastSync: lastSync, status: status
            )
        }
        let accounts = [
            link("never", lastSync: nil, status: nil),
            link("attention", status: "reauth-required"),
            link("healthy"),
            link("closed", closed: true, lastSync: nil),
            link("simplefin", source: "simpleFin", lastSync: nil),
        ]
        #expect(EnableBankingSyncView.accountsNeedingSync(accounts) == ["never", "attention"])
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

    @Test func enableBankingRemoteOffersItsOwnLinksAttentionFirst() {
        let result = BankAccountLinkView.linkableAccounts(
            accounts: [account("free"), account("ok"), account("stale"), account("sf"), account("closed", closed: true)],
            linked: [
                link("ok", source: "enableBanking"),
                link("stale", source: "enableBanking", status: "reauth-required"),
                link("sf", source: "simpleFin"),
            ],
            remoteSource: .enableBanking
        )
        #expect(result.map(\.id) == ["stale", "ok", "free"])
    }
}
