import Testing
import SwiftUI
import UIKit
@testable import Actuali

struct CompactBudgetPresentationTests {
    @Test @MainActor func groupHeaderHeightDoesNotDependOnTotalsVisibility() throws {
        let store = BudgetStore.previewInstance()
        let totals = CategoryGroupTotals([
            category(budgeted: 50_000, spent: -31_500, available: 18_500),
        ])

        for showsSpent in [false, true] {
            let visibleHeader = CompactBudgetGroupHeader(
                name: "Emergency Savings",
                isCollapsed: false,
                totals: totals,
                showsSpent: showsSpent,
                onToggleCollapse: {}
            )
            .environmentObject(store)
            .frame(width: 390)
            let hiddenHeader = CompactBudgetGroupHeader(
                name: "Emergency Savings",
                isCollapsed: false,
                totals: nil,
                showsSpent: showsSpent,
                onToggleCollapse: {}
            )
            .environmentObject(store)
            .frame(width: 390)

            #expect(try renderedHeight(visibleHeader) == renderedHeight(hiddenHeader))
        }
    }

    @Test func envelopeOverviewUsesToBudgetAndHidesSpentWithoutAPlaceholder() {
        let budget = BudgetMonth(
            month: "2026-08",
            categoryBudgets: [
                category(budgeted: 50_000, spent: -31_500, available: 18_500),
            ],
            toBudget: 12_500
        )

        let overview = CompactBudgetOverview(
            budget: budget,
            showsSpent: false,
            currentMonth: "2026-08"
        )

        #expect(overview.leading == .init(label: "To Budget", amount: 12_500))
        #expect(overview.columns == [
            .init(label: "Budgeted", amount: 50_000),
            .init(label: "Balance", amount: 18_500),
        ])
        #expect(CompactBudgetTableLayout(isTrackingBudget: false, showsSpent: false).expenseColumns == [
            .budgeted,
            .balance,
        ])
    }

    @Test func groupHeaderPresentationOmitsEveryTotalWhenDisabled() {
        let totals = CategoryGroupTotals([
            category(budgeted: 50_000, spent: -31_500, available: 18_500),
        ])

        #expect(CompactBudgetGroupHeaderPresentation(totals: nil, showsSpent: true).columns.isEmpty)
        #expect(CompactBudgetGroupHeaderPresentation(totals: totals, showsSpent: false).columns == [
            .init(type: .budgeted, amount: 50_000),
            .init(type: .balance, amount: 18_500),
        ])
        #expect(CompactBudgetGroupHeaderPresentation(totals: totals, showsSpent: true).columns == [
            .init(type: .budgeted, amount: 50_000),
            .init(type: .spent, amount: -31_500),
            .init(type: .balance, amount: 18_500),
        ])
    }

    @Test func trackingOverviewUsesIncomeAndProjectedSavingsForCurrentMonth() {
        let budget = BudgetMonth(
            month: "2026-08",
            categoryBudgets: [
                category(budgeted: 80_000, spent: -60_000, available: 20_000),
            ],
            incomeCategories: [
                income(budgeted: 125_000, received: 110_000),
            ],
            toBudget: nil
        )

        let overview = CompactBudgetOverview(
            budget: budget,
            showsSpent: true,
            currentMonth: "2026-08"
        )

        #expect(overview.leading == .init(label: "Income", amount: 110_000))
        #expect(overview.columns == [
            .init(label: "Budgeted", amount: 80_000),
            .init(label: "Spent", amount: -60_000),
            .init(label: "Projected", amount: 45_000),
        ])
        #expect(CompactBudgetTableLayout(isTrackingBudget: true, showsSpent: true).incomeColumns == [
            .budgeted,
            .received,
        ])
    }

    @Test func pastTrackingOverviewUsesActualSavedAmount() {
        let budget = BudgetMonth(
            month: "2026-07",
            categoryBudgets: [
                category(budgeted: 80_000, spent: -60_000, available: 20_000),
            ],
            incomeCategories: [
                income(budgeted: 125_000, received: 110_000),
            ],
            toBudget: nil
        )

        let overview = CompactBudgetOverview(
            budget: budget,
            showsSpent: false,
            currentMonth: "2026-08"
        )

        #expect(overview.columns.last == .init(label: "Saved", amount: 50_000))
    }

    @Test func balanceToneDistinguishesEverySemanticStateAndPrivacyMasking() {
        #expect(CompactBalanceTone(amount: -1, isMasked: false) == .negative)
        #expect(CompactBalanceTone(amount: 0, isMasked: false) == .zero)
        #expect(CompactBalanceTone(amount: 1, isMasked: false) == .positive)
        #expect(CompactBalanceTone(amount: -1, isMasked: true) == .masked)
        #expect(CompactBalanceTone(amount: 0, isMasked: true) == .masked)
        #expect(CompactBalanceTone(amount: 1, isMasked: true) == .masked)
        #expect(CompactBalanceTone(amount: 1, isMasked: true).accessibilityStatus == "hidden")
    }

    private func category(budgeted: Int, spent: Int, available: Int) -> CategoryBudget {
        CategoryBudget(
            month: "2026-08",
            categoryId: "category",
            categoryName: "Groceries",
            groupId: "group",
            groupName: "Essentials",
            groupSortOrder: 1,
            categorySortOrder: 1,
            budgeted: budgeted,
            spent: spent,
            available: available,
            carryover: 0
        )
    }

    private func income(budgeted: Int, received: Int) -> IncomeCategory {
        IncomeCategory(
            month: "2026-08",
            categoryId: "income",
            categoryName: "Salary",
            groupName: "Income",
            sortOrder: 1,
            budgeted: budgeted,
            received: received
        )
    }

    @MainActor
    private func renderedHeight<Content: View>(_ view: Content) throws -> Int {
        try renderedImage(view).height
    }

    @MainActor
    private func renderedImage<Content: View>(_ view: Content) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.uiImage?.cgImage)
    }
}
