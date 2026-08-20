import Testing
import SwiftUI
import UIKit
@testable import Actuali

struct ListBudgetPresentationTests {
    @Test func listStyleRequiresAnOpaqueNavigationBar() {
        #expect(BudgetNavigationBarAppearance(style: .list).isOpaque)
        #expect(!BudgetNavigationBarAppearance(style: .clean).isOpaque)
        #expect(!BudgetNavigationBarAppearance(style: .detailed).isOpaque)
    }

    @Test func summarySpacingDependsOnlyOnStyle() {
        let listSpacing = BudgetSummarySpacing(style: .list)
        #expect(listSpacing.horizontalPadding == 0)
        #expect(listSpacing.topPadding == 0)
        #expect(listSpacing.bottomPadding == 0)

        for style in [BudgetDisplayStyle.clean, .detailed] {
            let spacing = BudgetSummarySpacing(style: style)
            #expect(spacing.horizontalPadding == 4)
            #expect(spacing.topPadding == 8)
            #expect(spacing.bottomPadding == 8)
        }
    }

    @Test @MainActor func groupHeadersHaveNoSeparatorPixels() throws {
        let store = BudgetStore.previewInstance()
        let totals = CategoryGroupTotals([
            category(budgeted: 50_000, spent: -31_500, available: 18_500),
        ])
        let expenseHeader = ListBudgetGroupHeader(
            name: "Essentials",
            isCollapsed: false,
            totals: totals,
            showsSpent: false,
            onToggleCollapse: {}
        )
        .environmentObject(store)
        .frame(width: 390)
        let incomeHeader = ListIncomeGroupHeader(
            name: "Income",
            totalBudgeted: 125_000,
            totalReceived: 110_000,
            showsBudgeted: true
        )
        .environmentObject(store)
        .frame(width: 390)

        try #expect(hasUniformVerticalEdge(expenseHeader))
        try #expect(hasUniformVerticalEdge(incomeHeader))
    }

    @Test @MainActor func categoryRowsKeepTheSourceListRowHeight() throws {
        let store = BudgetStore.previewInstance()
        let expenseRow = ListCategoryBudgetRow(
            category: category(budgeted: 50_000, spent: -31_500, available: 18_500),
            showsSpent: false,
            showsProgressBars: false
        )
        .environmentObject(store)
        .frame(width: 390)
        let incomeRow = ListIncomeCategoryRow(
            income: income(budgeted: 125_000, received: 110_000),
            showsBudgeted: true
        )
        .environmentObject(store)
        .frame(width: 390)

        #expect(try renderedHeight(expenseRow) >= 44)
        #expect(try renderedHeight(incomeRow) >= 44)
    }

    @Test func envelopeOverviewUsesToBudgetAndHidesSpentWithoutAPlaceholder() {
        let budget = BudgetMonth(
            month: "2026-08",
            categoryBudgets: [
                category(budgeted: 50_000, spent: -31_500, available: 18_500),
            ],
            toBudget: 12_500
        )

        let overview = ListBudgetOverview(
            budget: budget,
            showsSpent: false,
            currentMonth: "2026-08"
        )

        #expect(overview.leading == .init(label: "To Budget", amount: 12_500))
        #expect(overview.columns == [
            .init(label: "Budgeted", amount: 50_000),
            .init(label: "Balance", amount: 18_500),
        ])
        #expect(ListBudgetTableLayout(isTrackingBudget: false, showsSpent: false).expenseColumns == [
            .budgeted,
            .balance,
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

        let overview = ListBudgetOverview(
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
        #expect(ListBudgetTableLayout(isTrackingBudget: true, showsSpent: true).incomeColumns == [
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

        let overview = ListBudgetOverview(
            budget: budget,
            showsSpent: false,
            currentMonth: "2026-08"
        )

        #expect(overview.columns.last == .init(label: "Saved", amount: 50_000))
    }

    @Test func balanceToneDistinguishesEverySemanticStateAndPrivacyMasking() {
        #expect(ListBalanceTone(amount: -1, isMasked: false) == .negative)
        #expect(ListBalanceTone(amount: 0, isMasked: false) == .zero)
        #expect(ListBalanceTone(amount: 1, isMasked: false) == .positive)
        #expect(ListBalanceTone(amount: -1, isMasked: true) == .masked)
        #expect(ListBalanceTone(amount: 0, isMasked: true) == .masked)
        #expect(ListBalanceTone(amount: 1, isMasked: true) == .masked)
        #expect(ListBalanceTone(amount: 1, isMasked: true).accessibilityStatus == "hidden")
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
    private func hasUniformVerticalEdge<Content: View>(_ view: Content) throws -> Bool {
        let image = try renderedImage(view)
        let sampleX = 8
        let topIsUniform = try pixel(in: image, x: sampleX, y: 0)
            == pixel(in: image, x: sampleX, y: 2)
        let bottomIsUniform = try pixel(in: image, x: sampleX, y: image.height - 1)
            == pixel(in: image, x: sampleX, y: image.height - 3)
        return topIsUniform && bottomIsUniform
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

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
        return Array(UnsafeBufferPointer(start: bytes + offset, count: image.bitsPerPixel / 8))
    }
}
