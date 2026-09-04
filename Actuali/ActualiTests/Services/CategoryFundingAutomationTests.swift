import Foundation
import Testing
@testable import Actuali

struct CategoryFundingAutomationTests {
    @Test func shortfallFundsOnlyNewOverspending() {
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: 50) == 0)
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: -30) == 30)
        #expect(CategoryFundingAutomation.shortfall(transactionAmount: -50, availableAfterTransaction: -550) == 50)
    }

    @Test func fundingSourcesRespectBudgetRules() {
        #expect(CategoryFundingAutomation.fundingDecision(transactionAmount: -50, availableAfterTransaction: -50, fundingSource: .toBudget) == .fund(50))
        #expect(CategoryFundingAutomation.fundingDecision(transactionAmount: -50, availableAfterTransaction: -50, fundingSource: .toBudget, isTrackingBudget: true) == .invalidSource)
        #expect(CategoryFundingAutomation.fundingDecision(transactionAmount: -50, availableAfterTransaction: -30, targetCategoryId: "a", fundingSource: .category("b"), sourceAvailable: 30) == .fund(30))
        #expect(CategoryFundingAutomation.fundingDecision(transactionAmount: -50, availableAfterTransaction: -30, targetCategoryId: "a", fundingSource: .category("b"), sourceAvailable: 20) == .insufficientSource)
        #expect(CategoryFundingAutomation.fundingDecision(transactionAmount: -50, availableAfterTransaction: -50, targetCategoryId: "a", fundingSource: .category("a"), sourceAvailable: 100) == .sameSourceAndTarget)
    }

    @Test func configurationRoundTrips() {
        let suite = "CategoryFundingAutomationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = CategoryFundingAutomationConfiguration(isEnabled: true, accountId: "account", fundingSource: .category("reserve"))
        CategoryFundingAutomation.saveConfiguration(configuration, for: "budget", defaults: defaults)
        #expect(CategoryFundingAutomation.loadConfiguration(for: "budget", defaults: defaults) == configuration)
    }
}