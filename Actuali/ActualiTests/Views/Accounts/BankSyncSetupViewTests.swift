import Foundation
import Testing
@testable import Actuali

struct BankSyncSetupViewTests {
    /// Backing out of Apple's consent sheet reports `.denied`, and FinanceKit
    /// never asks again — so the denied row must still lead somewhere (GH #555).
    @Test func deniedWalletAccessOffersSettings() {
        #expect(BankSyncSetupView.walletRow(for: .denied) == .openSettings)
    }

    @Test func otherWalletStatesKeepTheirRows() {
        #expect(BankSyncSetupView.walletRow(for: .authorized) == .accounts)
        #expect(BankSyncSetupView.walletRow(for: .notDetermined) == .connect)
        #expect(BankSyncSetupView.walletRow(for: .unsupported) == .connect)
    }

    /// Wallet data is iPhone-only and currently US-only. Offering the provider
    /// on a device where FinanceKit has nothing would open a connect button
    /// that cannot work — and that calls `FinanceStore` directly, which traps
    /// in an unsigned simulator build.
    @Test func walletProviderHiddenWhereWalletIsUnavailable() {
        #expect(!BankSyncSetupView.showsWalletRow(for: .unsupported))
        #expect(BankSyncSetupView.showsWalletRow(for: .notDetermined))
        #expect(BankSyncSetupView.showsWalletRow(for: .denied))
        #expect(BankSyncSetupView.showsWalletRow(for: .authorized))
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
