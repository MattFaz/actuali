import Testing
@testable import Actuali

/// Actual's transfer category rule, shared by the add/edit form and every
/// transfer save path: only the on-budget leg of an on/off-budget pair takes
/// a category (GH #561).
struct BudgetStoreTransferCategoryRuleTests {
    private let offBudget: Set = ["acct-brokerage", "acct-loan"]

    private func takes(leg: String?, partner: String?) -> Bool {
        BudgetStore.transferLegTakesCategory(leg: leg, partner: partner, offBudgetAccountIds: offBudget)
    }

    @Test func onBudgetToOnBudgetTakesNone() {
        #expect(!takes(leg: "acct-checking", partner: "acct-card"))
        #expect(!takes(leg: "acct-card", partner: "acct-checking"))
    }

    @Test func onOffBudgetPairTakesOneOnTheOnBudgetLegInBothDirections() {
        // A new transfer counts either direction: checking → loan and
        // loan → checking both leave checking as the categorized leg.
        #expect(takes(leg: "acct-checking", partner: "acct-loan"))
        #expect(!takes(leg: "acct-loan", partner: "acct-checking"))
    }

    @Test func offBudgetToOffBudgetTakesNone() {
        #expect(!takes(leg: "acct-brokerage", partner: "acct-loan"))
    }

    @Test func missingAccountTakesNone() {
        #expect(!takes(leg: "acct-checking", partner: nil))
        #expect(!takes(leg: nil, partner: "acct-loan"))
    }

    @Test func retargetingTheOtherAccountTogglesTheCategory() {
        // The form's row follows the To picker round trip: hidden on an
        // on-budget partner, back again on an off-budget one.
        #expect(takes(leg: "acct-checking", partner: "acct-loan"))
        #expect(!takes(leg: "acct-checking", partner: "acct-card"))
        #expect(takes(leg: "acct-checking", partner: "acct-loan"))
    }
}
