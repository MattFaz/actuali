import Foundation
import Testing
@testable import Actuali

struct EnableBankingLinksTests {
    private func remote(_ id: String, _ name: String) -> BankSyncRemoteAccount {
        BankSyncRemoteAccount(
            id: id, name: name, institutionId: id, institutionName: "Revolut", balanceCents: nil, source: .enableBanking
        )
    }

    private func link(
        _ id: String,
        _ name: String,
        external: String,
        bank: String? = "Revolut",
        source: BankSyncSource = .enableBanking,
        closed: Bool = false
    ) -> BankSyncAccount {
        BankSyncAccount(
            id: id, name: name, externalAccountId: external, syncSource: source.rawValue,
            offBudget: false, closed: closed, institutionName: bank
        )
    }

    private func renewals(
        _ remotes: [BankSyncRemoteAccount],
        reauthorizing accountId: String = "a",
        bank: String = "Revolut",
        linked: [BankSyncAccount]
    ) -> [String: String] {
        EnableBankingLinks.renewals(of: remotes, reauthorizing: accountId, bankName: bank, linked: linked)
            .mapValues(\.id)
    }

    @Test func theOnlyAccountTheBankReturnsRenewsTheReauthorizedLink() {
        // Named differently on purpose: the budget account is the person's own name for it.
        let linked = [link("a", "Daily", external: "old")]
        #expect(renewals([remote("new", "Main")], linked: linked) == ["a": "new"])
    }

    @Test func accountsRenewTheLinkThatCarriesTheirName() {
        let linked = [link("a", "Current", external: "old-1"), link("b", "Savings", external: "old-2")]
        let remotes = [remote("new-2", " savings "), remote("new-1", "Current")]
        #expect(renewals(remotes, linked: linked) == ["a": "new-1", "b": "new-2"])
    }

    @Test func theAccountLeftOverAfterNamesGoesToTheReauthorizedLink() {
        let linked = [link("a", "Daily", external: "old-1"), link("b", "Savings", external: "old-2")]
        let remotes = [remote("new-1", "Main"), remote("new-2", "Savings")]
        #expect(renewals(remotes, linked: linked) == ["a": "new-1", "b": "new-2"])
    }

    @Test func severalUnnamedAccountsAreLeftToLinkByHand() {
        let linked = [link("a", "Daily", external: "old")]
        #expect(renewals([remote("new-1", "EUR"), remote("new-2", "USD")], linked: linked).isEmpty)
    }

    @Test func aNameSharedByTwoAccountsPairsNothing() {
        let twoRemotes = [remote("new-1", "M Evers"), remote("new-2", "M Evers")]
        #expect(renewals(twoRemotes, linked: [link("a", "M Evers", external: "old")]).isEmpty)

        let twoLinks = [link("a", "Joint", external: "old-1"), link("b", "Joint", external: "old-2")]
        #expect(renewals([remote("new-1", "Joint"), remote("new-2", "Other")], linked: twoLinks).isEmpty)
    }

    @Test func anIdTheBankKeptNeedsNoRenewal() {
        let linked = [link("a", "Daily", external: "same"), link("b", "Savings", external: "old")]
        // "a" still answers under its id, so the one new account is not handed to it.
        #expect(renewals([remote("same", "Main"), remote("new", "Pocket")], linked: linked).isEmpty)
        #expect(renewals([remote("same", "Main"), remote("new", "Pocket")], reauthorizing: "b", linked: linked)
            == ["b": "new"])
    }

    @Test func onlyTheReauthorizedBanksOpenEnableBankingLinksAreRenewed() {
        let linked = [
            link("a", "Daily", external: "old"),
            link("other-bank", "Savings", external: "old-2", bank: "ING"),
            link("simplefin", "Savings", external: "old-3", source: .simpleFin),
            link("closed", "Savings", external: "old-4", closed: true),
        ]
        let remotes = [remote("new-1", "Main"), remote("new-2", "Savings")]
        // "Savings" matches no link of this bank, which leaves two accounts and no certain pair.
        #expect(renewals(remotes, linked: linked).isEmpty)
        #expect(renewals([remote("new-1", "Main")], linked: linked) == ["a": "new-1"])
    }

    @Test func whatTheTransactionsProvedStandsAndTheRestIsPairedAroundIt() {
        let linked = [link("a", "Daily", external: "old-1"), link("b", "Savings", external: "old-2")]
        let remotes = [remote("new-1", "Savings"), remote("new-2", "Main")]
        // By name alone "b" would take new-1; its transactions say that is "a".
        let proven = ["a": remotes[0]]
        let result = EnableBankingLinks.renewals(
            of: remotes, reauthorizing: "b", bankName: "Revolut", linked: linked, proven: proven
        )
        #expect(result.mapValues(\.id) == ["a": "new-1", "b": "new-2"])
    }

    @Test func aNewAuthorizationLeavesItsBanksStaleLinksAndFreeAccountsToSettle() {
        let linked = [
            link("a", "Daily", external: "old"),
            link("kept", "Joint", external: "same"),
            link("other-bank", "Savings", external: "old-2", bank: "ING"),
            link("closed", "Old", external: "old-3", closed: true),
        ]
        let remotes = [remote("same", "Joint"), remote("new-1", "Main"), remote("new-2", "Pocket")]
        let open = EnableBankingLinks.unsettled(of: remotes, bankName: "Revolut", linked: linked)
        #expect(open.links.map(\.id) == ["a"])
        #expect(open.remotes.map(\.id) == ["new-1", "new-2"])
    }

    @Test func authorizingADifferentBankRenewsNothing() {
        let linked = [link("a", "Daily", external: "old")]
        #expect(renewals([remote("new", "Daily")], bank: "ING", linked: linked).isEmpty)
        #expect(renewals([remote("new", "Daily")], reauthorizing: "gone", linked: linked).isEmpty)
        #expect(renewals([remote("new", "Daily")], linked: [link("a", "Daily", external: "old", bank: nil)]).isEmpty)
    }
}
