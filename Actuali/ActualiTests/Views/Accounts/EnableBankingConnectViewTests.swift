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

    // MARK: - Accounts

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
