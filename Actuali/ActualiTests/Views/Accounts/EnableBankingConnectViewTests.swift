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
