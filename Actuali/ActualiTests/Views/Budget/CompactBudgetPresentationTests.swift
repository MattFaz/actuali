import Testing
import SwiftUI
import UIKit
@testable import Actuali

struct CompactBudgetPresentationTests {

    private var actualiBundle: Bundle {
        Bundle(identifier: "com.mfazz.ActualiOS")!
    }
    @Test @MainActor func groupHeaderHeightDoesNotDependOnTotalsVisibility() throws {
        let store = BudgetStore.previewInstance()
        let totals = CategoryGroupTotals([
            category(budgeted: 50_000, spent: -31_500, available: 18_500),
        ])

        for showsSpent in [false, true] {
            let visibleHeader = CompactBudgetGroupHeader(
                name: "Emergency Savings",
                isCollapsed: false,
                onSetHidden: { _ in },
                totals: totals,
                showsSpent: showsSpent,
                onToggleCollapse: {}
            )
            .environmentObject(store)
            .frame(width: 390)
            let hiddenHeader = CompactBudgetGroupHeader(
                name: "Emergency Savings",
                isCollapsed: false,
                onSetHidden: { _ in },
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

        #expect(overview.leading == .init(kind: .toBudget, amount: 12_500))
        #expect(overview.columns == [
            .init(kind: .budgeted, amount: 50_000),
            .init(kind: .balance, amount: 18_500),
        ])
        #expect(CompactBudgetTableLayout(isTrackingBudget: false, showsSpent: false).expenseColumns == [
            .budgeted,
            .balance,
        ])
        #expect(CompactBudgetTableLayout(isTrackingBudget: false, showsSpent: false).incomeColumns == [
            nil,
            .received,
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

        #expect(overview.leading == .init(kind: .income, amount: 110_000))
        #expect(overview.columns == [
            .init(kind: .budgeted, amount: 80_000),
            .init(kind: .spent, amount: -60_000),
            .init(kind: .projected, amount: 45_000),
        ])
        #expect(CompactBudgetTableLayout(isTrackingBudget: true, showsSpent: true).incomeColumns == [
            .budgeted,
            nil,
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

        #expect(overview.columns.last == .init(kind: .saved, amount: 50_000))
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

    @Test func compactDisplayLabelsLocalizeWithoutChangingStableIdentities() {
        let columnIdentities: [(CompactBudgetColumn, String)] = [
            (.budgeted, "Budgeted"), (.spent, "Spent"), (.balance, "Balance"), (.received, "Received")
        ]
        let statIdentities: [(CompactBudgetOverview.Stat.Kind, String)] = [
            (.toBudget, "toBudget"), (.income, "income"), (.budgeted, "budgeted"),
            (.spent, "spent"), (.saved, "saved"), (.projected, "projected"), (.balance, "balance")
        ]
        for (column, rawValue) in columnIdentities {
            #expect(column.rawValue == rawValue)
        }
        for (kind, rawValue) in statIdentities {
            #expect(kind.rawValue == rawValue)
        }

        let columns: [(CompactBudgetColumn, [String])] = [
            (.budgeted, ["Budgeted", "Budgété", "Presupuestado", "Orçado", "Budgetiert", "Budgetizzato", "Begroot"]),
            (.spent, ["Spent", "Dépensé", "Gastado", "Gasto", "Ausgegeben", "Speso", "Besteed"]),
            (.balance, ["Balance", "Solde", "Saldo", "Saldo", "Saldo", "Saldo", "Saldo"]),
            (.received, ["Received", "Reçu", "Recibido", "Recebido", "Erhalten", "Ricevuto", "Ontvangen"])
        ]
        let stats: [(CompactBudgetOverview.Stat.Kind, [String])] = [
            (.toBudget, ["To Budget", "À budgéter", "Por presupuestar", "A orçar", "Zu budgetieren", "Da assegnare", "Te budgetteren"]),
            (.income, ["Income", "Revenus", "Ingresos", "Receitas", "Einkommen", "Reddito", "Inkomen"]),
            (.budgeted, ["Budgeted", "Budgété", "Presupuestado", "Orçado", "Budgetiert", "Budgetizzato", "Begroot"]),
            (.spent, ["Spent", "Dépensé", "Gastado", "Gasto", "Ausgegeben", "Speso", "Besteed"]),
            (.saved, ["Saved", "Enregistré", "Guardado", "Salvo", "Gespeichert", "Salvato", "Opgeslagen"]),
            (.projected, ["Projected", "Prévisionnel", "Previsto", "Projetado", "Prognose", "Previsto", "Verwacht"]),
            (.balance, ["Balance", "Solde", "Saldo", "Saldo", "Saldo", "Saldo", "Saldo"])
        ]
        let locales = ["en_US", "fr_FR", "es_ES", "pt_BR", "de_DE", "it_IT", "nl_NL"]

        for (index, identifier) in locales.enumerated() {
            let locale = Locale(identifier: identifier)
            for (column, values) in columns {
                #expect(column.label(locale: locale, bundle: actualiBundle) == values[index])
            }
            for (kind, values) in stats {
                #expect(CompactBudgetOverview.Stat(kind: kind, amount: 0)
                    .label(locale: locale, bundle: actualiBundle) == values[index])
            }
        }
    }

    @Test func compactAccessibilityHelpersKeepCompleteArgumentShapes() {
        let locale = Locale(identifier: "fr_FR")
        #expect(CompactBudgetAccessibility.editBudget(
            category: "Courses",
            amount: "10,00 €",
            locale: locale,
            bundle: actualiBundle
        ) == "Modifier le montant prévu pour Courses, 10,00 € prévu")
        #expect(CompactBudgetAccessibility.monthTransactions(
            category: "Courses",
            month: "août 2026",
            amountLabel: "dépensé",
            amount: "5,00 €",
            locale: locale,
            bundle: actualiBundle
        ) == "Transactions de Courses en août 2026 dépensé 5,00 €")
        #expect(CompactBudgetAccessibility.details(
            category: "Courses",
            status: "Financé",
            locale: locale,
            bundle: actualiBundle
        ) == "Détails pour Courses, Financé")
        #expect(CompactBudgetAccessibility.incomeBudgeted(
            category: "Salaire",
            amount: "1 000,00 €",
            locale: locale,
            bundle: actualiBundle
        ) == "Budget prévu pour Salaire, 1 000,00 €")
    }

    @Test @MainActor func balanceColorUsesGoalStateWhenEnabled() {
        var underfunded = category(budgeted: 5_000, spent: 0, available: 5_000)
        underfunded.goal = 10_000

        #expect(balanceColor(underfunded, goalsEnabled: true, zero: .secondary) == .orange)
        #expect(balanceColor(underfunded, goalsEnabled: false, zero: .secondary) == .green)
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
