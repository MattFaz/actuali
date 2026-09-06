import Foundation
import Testing
@testable import Actuali

struct CategoryBudgetProgressTests {

    private var actualiBundle: Bundle {
        Bundle(identifier: "com.mfazz.ActualiOS")!
    }

    private func makeCategory(
        id: String = "cat1",
        groupId: String = "g1",
        budgeted: Int,
        spent: Int,
        available: Int,
        carryover: Int = 0
    ) -> CategoryBudget {
        CategoryBudget(
            month: "2026-07",
            categoryId: id,
            categoryName: "Groceries",
            groupId: groupId,
            groupName: "Everyday",
            groupSortOrder: 0,
            categorySortOrder: 0,
            budgeted: budgeted,
            spent: spent,
            available: available,
            carryover: carryover
        )
    }

    @Test func halfSpentIsHalfFull() {
        let category = makeCategory(budgeted: 10000, spent: -5000, available: 5000)
        #expect(category.progressFraction == 0.5)
    }

    @Test func nothingSpentIsEmpty() {
        let category = makeCategory(budgeted: 10000, spent: 0, available: 10000)
        #expect(category.progressFraction == 0.0)
    }

    @Test func overspentIsCappedAtFull() {
        let category = makeCategory(budgeted: 10000, spent: -12000, available: -2000)
        #expect(category.progressFraction == 1.0)
    }

    @Test func spendingWithNoBudgetIsFull() {
        let category = makeCategory(budgeted: 0, spent: -3000, available: -3000)
        #expect(category.progressFraction == 1.0)
    }

    @Test func carryoverCountsTowardCapacity() {
        // Nothing budgeted this month, but carryover leaves 5000 available
        // after spending 5000: the bar should read half, matching the
        // displayed Available amount.
        let category = makeCategory(budgeted: 0, spent: -5000, available: 5000, carryover: 10000)
        #expect(category.progressFraction == 0.5)
    }

    @Test func zeroActivityHasNoFraction() {
        let category = makeCategory(budgeted: 0, spent: 0, available: 0)
        #expect(category.progressFraction == 0.0)
    }

    @Test func barHiddenWhenNoBudgetAndNoSpending() {
        let category = makeCategory(budgeted: 0, spent: 0, available: 0)
        #expect(!category.showsProgressBar)
    }

    @Test func barShownWhenBudgeted() {
        let category = makeCategory(budgeted: 10000, spent: 0, available: 10000)
        #expect(category.showsProgressBar)
    }

    @Test func barShownWhenSpendingWithoutBudget() {
        let category = makeCategory(budgeted: 0, spent: -3000, available: -3000)
        #expect(category.showsProgressBar)
    }

    @Test func progressStatesDistinguishActionableCategoryConditions() {
        #expect(makeCategory(budgeted: 0, spent: 0, available: 0).progressState == .unassigned)
        #expect(makeCategory(budgeted: 10000, spent: 0, available: 10000).progressState == .funded)
        #expect(makeCategory(budgeted: 10000, spent: -4000, available: 6000).progressState == .spending)
        #expect(makeCategory(budgeted: 10000, spent: -10000, available: 0).progressState == .spent)
        #expect(makeCategory(budgeted: 10000, spent: -12000, available: -2000).progressState == .overspent)
    }

    @Test func progressStatusesStayLocalizedAcrossSupportedLocales() {
        let expected: [String: [String]] = [
            "en_US": ["Overspent", "Fully spent", "Partially spent", "Funded", "No money assigned"],
            "fr_FR": ["Dépassement", "Entièrement dépensé", "Partiellement dépensé", "Financé", "Aucun argent attribué"],
            "es_ES": ["Excedido", "Totalmente gastado", "Parcialmente gastado", "Financiado", "Sin dinero asignado"],
            "pt_BR": ["Excedido", "Totalmente gasto", "Parcialmente gasto", "Financiado", "Nenhum dinheiro atribuído"],
            "de_DE": ["Überzogen", "Vollständig ausgegeben", "Teilweise ausgegeben", "Finanziert", "Kein Geld zugewiesen"],
            "it_IT": ["In eccesso", "Speso interamente", "Speso parzialmente", "Finanziato", "Nessun importo assegnato"],
            "nl_NL": ["Overschreden", "Volledig uitgegeven", "Gedeeltelijk uitgegeven", "Gefinancierd", "Geen geld toegewezen"]
        ]
        let states: [CategoryProgressState] = [.overspent, .spent, .spending, .funded, .unassigned]

        for (identifier, values) in expected {
            let locale = Locale(identifier: identifier)
            for (state, value) in zip(states, values) {
                #expect(state.statusText(locale: locale, bundle: actualiBundle) == value)
            }
        }
    }

    @Test func quickAssignUsesActualHistoryAndProducesFinalAmounts() {
        let current = makeCategory(budgeted: 10000, spent: -4000, available: 6000)
        let history = [
            makeCategory(budgeted: 9000, spent: -8000, available: 1000),
            makeCategory(budgeted: 6000, spent: -4000, available: 2000),
            makeCategory(budgeted: 3000, spent: 1000, available: 4000)
        ]
        let byKind = Dictionary(uniqueKeysWithValues:
            current.quickAssignSuggestions(history: history).map { ($0.kind, $0.amount) })

        #expect(byKind[.spentLastMonth] == 8000)
        #expect(byKind[.assignedLastMonth] == 9000)
        #expect(byKind[.averageSpent] == 4000)
        #expect(byKind[.resetAvailable] == 4000)
        #expect(byKind[.setToZero] == 0)
    }

    @Test func quickAssignOmitsUnavailableHistoricalChoices() {
        let current = makeCategory(budgeted: 0, spent: 0, available: 0)
        #expect(current.quickAssignSuggestions(history: []).isEmpty)
    }

    // With one history month the average equals Spent Last Month; offering
    // both would just duplicate the suggestion.
    @Test func quickAssignOmitsAverageForASingleHistoryMonth() {
        let current = makeCategory(budgeted: 10000, spent: -4000, available: 6000)
        let history = [makeCategory(budgeted: 9000, spent: -8000, available: 1000)]
        let kinds = current.quickAssignSuggestions(history: history).map(\.kind)
        #expect(!kinds.contains(.averageSpent))
        #expect(kinds.contains(.spentLastMonth))
    }

    @Test func filterMatchesTheStatesItNames() {
        let overspent = makeCategory(budgeted: 0, spent: -100, available: -100)
        let unassigned = makeCategory(budgeted: 0, spent: 0, available: 0)
        let funded = makeCategory(budgeted: 100, spent: 0, available: 100)
        let approaching = makeCategory(budgeted: 10000, spent: -8000, available: 2000)

        #expect(BudgetCategoryFilter.all.includes(funded))
        #expect(BudgetCategoryFilter.overspent.includes(overspent))
        #expect(!BudgetCategoryFilter.overspent.includes(unassigned))
        #expect(BudgetCategoryFilter.unassigned.includes(unassigned))
        #expect(BudgetCategoryFilter.needsAttention.includes(overspent))
        #expect(BudgetCategoryFilter.needsAttention.includes(unassigned))
        #expect(!BudgetCategoryFilter.needsAttention.includes(funded))
        #expect(BudgetCategoryFilter.onTrack.includes(funded))
        #expect(!BudgetCategoryFilter.onTrack.includes(unassigned))
        #expect(BudgetCategoryFilter.approachingLimit.includes(approaching))
        #expect(!BudgetCategoryFilter.approachingLimit.includes(funded))
        #expect(!BudgetCategoryFilter.approachingLimit.includes(overspent))
    }

    @Test(arguments: ["en_US", "fr_FR", "pt_BR", "es_ES", "de_DE", "it_IT", "nl_NL"])
    func filterTitlesSelectTheCorrectPluralBranchForZeroOneAndTwo(identifier: String) {
        let locale = Locale(identifier: identifier)
        let titles = (0...2).map { count in
            BudgetCategoryFilter.needsAttention.title(
                count: count,
                isTrackingBudget: false,
                locale: locale,
                bundle: actualiBundle
            )
        }

        #expect(titles[0].contains("0"))
        #expect(titles[1].contains("1"))
        #expect(titles[2].contains("2"))
        if identifier == "en_US" {
            #expect(titles[0] == "Needs attention (0)")
            #expect(titles[1] == "Needs attention (1)")
            #expect(titles[2] == "Needs attention (2)")
        } else if identifier == "fr_FR" {
            #expect(titles[0] == "Nécessite une attention (0)")
            #expect(titles[1] == "Nécessite une attention (1)")
            #expect(titles[2] == "Nécessitent une attention (2)")
        } else if identifier == "pt_BR" {
            #expect(titles[0] == "Precisa de atenção (0)")
            #expect(titles[1] == "Precisa de atenção (1)")
            #expect(titles[2] == "Precisam de atenção (2)")
        } else if identifier == "es_ES" {
            #expect(titles[0] == "Requieren atención (0)")
            #expect(titles[1] == "Requiere atención (1)")
            #expect(titles[2] == "Requieren atención (2)")
        } else if identifier == "de_DE" {
            #expect(titles[0] == "Benötigen Aufmerksamkeit (0)")
            #expect(titles[1] == "Benötigt Aufmerksamkeit (1)")
            #expect(titles[2] == "Benötigen Aufmerksamkeit (2)")
        } else if identifier == "it_IT" {
            #expect(titles[0] == "Richiedono attenzione (0)")
            #expect(titles[1] == "Richiede attenzione (1)")
            #expect(titles[2] == "Richiedono attenzione (2)")
        } else {
            #expect(titles[0] == "Hebben aandacht nodig (0)")
            #expect(titles[1] == "Heeft aandacht nodig (1)")
            #expect(titles[2] == "Hebben aandacht nodig (2)")
        }
    }

    @Test(arguments: ["fr_FR", "es_ES", "pt_BR", "de_DE", "it_IT", "nl_NL"])
    func everyFilterUsesLocalizedLabelsAndAccessibilityWrapper(identifier: String) {
        let locale = Locale(identifier: identifier)
        let wrapper = ReportStrings.text("Show %@ categories", locale: locale, bundle: actualiBundle)
        let englishWrapper = ReportStrings.text("Show %@ categories", locale: Locale(identifier: "en_US"), bundle: actualiBundle)

        #expect(wrapper != englishWrapper)
        for filter in BudgetCategoryFilter.allCases {
            for isTrackingBudget in [false, true] {
                for count in 0...2 {
                    let title = filter.title(
                        count: count,
                        isTrackingBudget: isTrackingBudget,
                        locale: locale,
                        bundle: actualiBundle
                    )
                    #expect(title.contains("\(count)"))
                    #expect(!title.contains("budget.filter."))
                    #expect(title != filter.title(
                        count: count,
                        isTrackingBudget: isTrackingBudget,
                        locale: Locale(identifier: "en_US"),
                        bundle: actualiBundle
                    ))

                    let accessibilityLabel = ReportStrings.format(
                        "Show %@ categories",
                        title,
                        locale: locale,
                        bundle: actualiBundle
                    )
                    #expect(accessibilityLabel == wrapper.replacingOccurrences(of: "%@", with: title))
                }
            }
        }
    }

    // The toolbar stepper abbreviates the month so its `.principal` item keeps
    // a width UIKit will still centre; everything that reads a month aloud or
    // in prose keeps the full name.
    @Test func toolbarMonthTitleAbbreviatesButKeepsTheYear() {
        let short = MonthPicker.shortTitle(for: "2026-09")
        #expect(short.contains("2026"))
        #expect(short.count <= MonthPicker.title(for: "2026-09").count)
        // Unparseable input falls through unchanged, like `title(for:)`.
        #expect(MonthPicker.shortTitle(for: "not-a-month") == "not-a-month")
    }

    @Test func monthKeysShiftAcrossTheYearBoundary() {
        #expect(BudgetStore.shiftBudgetMonth("2026-01", by: -1) == "2025-12")
        #expect(BudgetStore.shiftBudgetMonth("2026-12", by: 1) == "2027-01")
        #expect(BudgetStore.shiftBudgetMonth("2026-06", by: 0) == "2026-06")
        #expect(BudgetStore.shiftBudgetMonth("not-a-month", by: -1) == nil)
    }

    @Test func coverSourcesPrioritizeFullCoverageThenSameGroup() {
        let overspent = makeCategory(id: "target", groupId: "home", budgeted: 0, spent: -5000, available: -5000)
        let partialSameGroup = makeCategory(id: "partial", groupId: "home", budgeted: 3000, spent: 0, available: 3000)
        let largeOtherGroup = makeCategory(id: "large", groupId: "other", budgeted: 12000, spent: 0, available: 12000)
        let smallSameGroup = makeCategory(id: "small", groupId: "home", budgeted: 6000, spent: 0, available: 6000)
        let context = BudgetTransferContext(
            category: overspent,
            budget: BudgetMonth(
                month: overspent.month,
                categoryBudgets: [partialSameGroup, largeOtherGroup, smallSameGroup],
                toBudget: 0
            )
        )

        #expect(context.rankedCategories.map(\.categoryId)
            == ["small", "large", "partial"])
        #expect(!context.canUseToBudget)
    }
}
