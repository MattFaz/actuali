import Foundation
import Testing
@testable import Actuali

struct EnableBankingConnectViewTests {
    @Test func banksLoadOnlyWhenTheCountryChangedOrNothingIsLoaded() {
        #expect(EnableBankingConnectView.needsBankLoad(country: "NL", loadedCountry: nil))
        #expect(EnableBankingConnectView.needsBankLoad(country: "DE", loadedCountry: "NL"))
        #expect(!EnableBankingConnectView.needsBankLoad(country: "NL", loadedCountry: "NL"))
    }

    @Test func onlyAClosedSheetLeavesTheWaitRunning() {
        #expect(EnableBankingConnectView.isSheetClosed(OpenIDAuthError.cancelled))
        #expect(!EnableBankingConnectView.isSheetClosed(OpenIDAuthError.sessionFailed(URLError(.badURL))))
        #expect(!EnableBankingConnectView.isSheetClosed(OpenIDAuthError.noWindow))
        #expect(!EnableBankingConnectView.isSheetClosed(OpenIDAuthError.missingToken))
        #expect(!EnableBankingConnectView.isSheetClosed(URLError(.cancelled)))
    }

    @Test func noAccountsMessageOnlyForAnEmptyAuthorization() {
        let remote = BankSyncRemoteAccount(
            id: "r", name: "Current", institutionId: "i", institutionName: "Bank", balanceCents: nil, source: .enableBanking
        )
        #expect(EnableBankingConnectView.noAccountsMessage(for: []) != nil)
        #expect(EnableBankingConnectView.noAccountsMessage(for: [remote]) == nil)
    }

    @Test func defaultCountryUsesListedRegionElseFallback() {
        #expect(EnableBankingConnectView.defaultCountry(region: "DE") == "DE")
        #expect(EnableBankingConnectView.defaultCountry(region: "US") == "NL")
        #expect(EnableBankingConnectView.defaultCountry(region: nil) == "NL")
    }

    @Test func psuTypeOnlyFollowsTheChoiceWhenBothAreOffered() {
        func bank(_ types: [String]?) -> EnableBankingBank {
            EnableBankingBank(name: "B", country: "NL", psuTypes: types, beta: nil, maximumConsentValidity: nil)
        }
        #expect(EnableBankingConnectView.psuType(for: bank(["personal", "business"]), choice: "business") == "business")
        #expect(EnableBankingConnectView.psuType(for: bank(["business"]), choice: "personal") == "business")
        #expect(EnableBankingConnectView.psuType(for: bank(nil), choice: "personal") == "personal")
    }

    @Test func aLinkedAccountsBankIsFoundByTrimmedCaseInsensitiveName() {
        func bank(_ name: String) -> EnableBankingBank {
            EnableBankingBank(name: name, country: "NL", psuTypes: nil, beta: nil, maximumConsentValidity: nil)
        }
        let abn = bank("ABN AMRO")
        let ing = bank("ING")
        #expect(EnableBankingConnectView.bank(named: "ING", in: [abn, ing]) == ing)
        #expect(EnableBankingConnectView.bank(named: "  abn amro\n", in: [abn, ing]) == abn)
        #expect(EnableBankingConnectView.bank(named: "Rabobank", in: [abn, ing]) == nil)
        #expect(EnableBankingConnectView.bank(named: nil, in: [abn, ing]) == nil)
        #expect(EnableBankingConnectView.bank(named: "ING", in: []) == nil)
    }

    // MARK: - Renewing links on reauthorization

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
        EnableBankingConnectView.renewals(of: remotes, reauthorizing: accountId, bankName: bank, linked: linked)
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
        let result = EnableBankingConnectView.renewals(
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
        let open = EnableBankingConnectView.unsettled(of: remotes, bankName: "Revolut", linked: linked)
        #expect(open.links.map(\.id) == ["a"])
        #expect(open.remotes.map(\.id) == ["new-1", "new-2"])
    }

    @Test func authorizingADifferentBankRenewsNothing() {
        let linked = [link("a", "Daily", external: "old")]
        #expect(renewals([remote("new", "Daily")], bank: "ING", linked: linked).isEmpty)
        #expect(renewals([remote("new", "Daily")], reauthorizing: "gone", linked: linked).isEmpty)
        #expect(renewals([remote("new", "Daily")], linked: [link("a", "Daily", external: "old", bank: nil)]).isEmpty)
    }

    // MARK: - What is left to do after the bank answered

    @Test func progressSaysWhetherAnythingIsLeftToLink() {
        let remotes = [remote("r1", "Main"), remote("r2", "Savings")]
        let first = link("a", "Daily", external: "r1")
        let second = link("b", "Savings", external: "r2")
        #expect(EnableBankingConnectView.linkProgress(of: remotes, linked: []) == .none)
        #expect(EnableBankingConnectView.linkProgress(of: remotes, linked: [first]) == .some)
        #expect(EnableBankingConnectView.linkProgress(of: remotes, linked: [first, second]) == .all)
    }

    @Test func aLinkFromAnotherProviderDoesNotCountAsLinked() {
        // The same id under SimpleFIN is a different account.
        let other = link("a", "Daily", external: "r1", source: .simpleFin)
        #expect(EnableBankingConnectView.linkProgress(of: [remote("r1", "Main")], linked: [other]) == .none)
    }

    @Test func aSingleAccountThatImportsNothingYetIsAskedAboutDirectly() {
        let only = remote("r1", "Main")
        #expect(EnableBankingConnectView.directTarget(of: [only], linked: []) == only)
        // Already set up, for instance by a renewal: nothing to ask.
        #expect(EnableBankingConnectView.directTarget(of: [only], linked: [link("a", "Daily", external: "r1")]) == nil)
        // Several accounts are a choice, so they get the list.
        #expect(EnableBankingConnectView.directTarget(of: [only, remote("r2", "Savings")], linked: []) == nil)
        #expect(EnableBankingConnectView.directTarget(of: [], linked: []) == nil)
    }

    @Test func theHeadlineNamesTheBankAndTellsARenewalFromAConnection() {
        let connected = EnableBankingConnectView.headline(bank: "Revolut", renewed: false)
        let renewed = EnableBankingConnectView.headline(bank: "Revolut", renewed: true)
        #expect(connected.contains("Revolut"))
        #expect(renewed.contains("Revolut"))
        #expect(connected != renewed)
    }

    @Test func theNextStepFollowsWhatIsLeftToDo() {
        func step(_ progress: EnableBankingConnectView.LinkProgress, direct: Bool = false) -> String {
            EnableBankingConnectView.nextStep(bank: "Revolut", progress: progress, asksDirectly: direct)
        }
        // Open accounts are introduced as the bank's, one or several.
        #expect(step(.none).contains("Revolut"))
        #expect(step(.none, direct: true).contains("Revolut"))
        #expect(step(.none) != step(.none, direct: true))
        #expect(step(.some) == step(.none))
        #expect(step(.all) != step(.some))
    }

    // MARK: - Where a reauthorization stands

    private func step(
        _ remotes: [BankSyncRemoteAccount], linked: [BankSyncAccount]
    ) -> EnableBankingConnectView.ReauthorizationStep {
        EnableBankingConnectView.reauthorizationStep(of: remotes, reauthorizing: "a", linked: linked)
    }

    @Test func aReauthorizationIsDoneOnceTheAccountImportsFromAReturnedAccount() {
        let remotes = [remote("new", "Main"), remote("other", "Pocket")]
        // The other account the bank returned is not this screen's business.
        #expect(step(remotes, linked: [link("a", "Daily", external: "new")]) == .done)
    }

    @Test func anUnpairedAccountIsAskedAboutWithOnlyTheFreeAccounts() {
        let taken = remote("taken", "Savings")
        let free = [remote("new-1", "EUR"), remote("new-2", "USD")]
        let linked = [link("a", "Daily", external: "old"), link("b", "Savings", external: "taken")]
        #expect(step(free + [taken], linked: linked) == .ask(free))
    }

    @Test func nothingLeftToPickFromMeansTheAccountWasNotShared() {
        let linked = [link("a", "Daily", external: "old"), link("b", "Savings", external: "taken")]
        #expect(step([remote("taken", "Savings")], linked: linked) == .missing)
    }

    @Test func aLinkThroughAnotherProviderDoesNotSettleAReauthorization() {
        let linked = [link("a", "Daily", external: "new", source: .simpleFin)]
        #expect(step([remote("new", "Main")], linked: linked) == .ask([remote("new", "Main")]))
    }

    private func makeBank(_ name: String, beta: Bool? = nil) -> EnableBankingBank {
        EnableBankingBank(name: name, country: "NL", psuTypes: nil, beta: beta, maximumConsentValidity: nil)
    }

    @Test func searchMatchesBankNamesIgnoringCaseAndDiacritics() {
        let banks = [makeBank("ABN AMRO"), makeBank("ING"), makeBank("Crédit Agricole")]
        #expect(EnableBankingConnectView.filtered(banks, matching: "abn").map(\.name) == ["ABN AMRO"])
        #expect(EnableBankingConnectView.filtered(banks, matching: "credit").map(\.name) == ["Crédit Agricole"])
        #expect(EnableBankingConnectView.filtered(banks, matching: "  ING\n").map(\.name) == ["ING"])
        #expect(EnableBankingConnectView.filtered(banks, matching: "Rabobank").isEmpty)
    }

    @Test func anEmptyOrBlankSearchKeepsEveryBank() {
        let banks = [makeBank("ABN AMRO"), makeBank("ING")]
        #expect(EnableBankingConnectView.filtered(banks, matching: "") == banks)
        #expect(EnableBankingConnectView.filtered(banks, matching: " \n ") == banks)
    }

    @Test func searchLooksAtTheNameNotTheBetaLabel() {
        let banks = [makeBank("ING", beta: true)]
        #expect(EnableBankingConnectView.filtered(banks, matching: "beta").isEmpty)
    }

    @Test func onlyABetaBankIsLabelledAsBeta() {
        #expect(EnableBankingConnectView.title(for: makeBank("ING")) == "ING")
        #expect(EnableBankingConnectView.title(for: makeBank("ING", beta: false)) == "ING")
        let beta = EnableBankingConnectView.title(for: makeBank("ING", beta: true))
        #expect(beta != "ING")
        #expect(beta.contains("ING"))
    }
}
