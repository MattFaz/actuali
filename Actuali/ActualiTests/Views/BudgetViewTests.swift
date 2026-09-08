import Foundation
import Testing
@testable import Actuali

struct BudgetViewTests {

    private var appBundle: Bundle { .main }
    private var actualiBundle: Bundle {
        Bundle(identifier: "com.mfazz.ActualiOS")!
    }

    @Test func displayedGroupsIncludeIncomeWhenPresent() {
        let ids = BudgetView.displayedGroupIDs(
            groupIDs: ["essentials", "lifestyle"],
            hasIncome: true
        )

        #expect(ids == ["essentials", "lifestyle", BudgetView.incomeGroupCollapseID])
    }

    @Test func displayedGroupsExcludeIncomeWhenAbsent() {
        let ids = BudgetView.displayedGroupIDs(
            groupIDs: ["essentials", "lifestyle"],
            hasIncome: false
        )

        #expect(ids == ["essentials", "lifestyle"])
    }

    @Test func monthPickerTitleUsesRequestedLocale() {
        #expect(MonthPicker.title(for: "2026-09", locale: Locale(identifier: "en_US")) == "September 2026")
        #expect(MonthPicker.title(for: "2026-09", locale: Locale(identifier: "fr_FR")) == "septembre 2026")
        #expect(MonthPicker.title(for: "2026-09", locale: Locale(identifier: "pt_BR")) == "setembro de 2026")
        #expect(MonthPicker.title(for: "2026-09", locale: Locale(identifier: "de_DE")) == "September 2026")
    }

    @Test func monthPickerShortTitleUsesRequestedLocale() {
        #expect(MonthPicker.shortTitle(for: "2026-09", locale: Locale(identifier: "en_US")) == "Sep 2026")
        #expect(MonthPicker.shortTitle(for: "2026-09", locale: Locale(identifier: "fr_FR")) == "sept. 2026")
        #expect(MonthPicker.shortTitle(for: "2026-09", locale: Locale(identifier: "pt_BR")) == "set. de 2026")
        #expect(MonthPicker.shortTitle(for: "2026-09", locale: Locale(identifier: "de_DE")) == "Sept. 2026")
    }

    @Test(arguments: [
        "2026-00", "2026-13", "2026-9", "26-09",
        "2026--09", "2026-09-", "2026-+9"
    ])
    func monthPickerRejectsMalformedMonths(_ month: String) {
        #expect(MonthPicker.date(fromMonth: month) == nil)
        #expect(MonthPicker.title(for: month, locale: Locale(identifier: "en_US")) == month)
    }

    @Test func quickAssignTitlesUseRequestedLocale() {
        let french = Locale(identifier: "fr_FR")
        #expect(CategoryBudgetDetailSheet.quickAssignTitle(
            for: .spentLastMonth,
            isTracking: false,
            historyCount: 2,
            locale: french,
            bundle: appBundle
        ) == "Dépenses du mois dernier")
        #expect(CategoryBudgetDetailSheet.quickAssignTitle(
            for: .averageSpent,
            isTracking: false,
            historyCount: 2,
            locale: french,
            bundle: appBundle
        ) == "Dépense moyenne (sur 2 mois)")
        #expect(CategoryBudgetDetailSheet.quickAssignTitle(
            for: .assignedLastMonth,
            isTracking: true,
            historyCount: 2,
            locale: french,
            bundle: appBundle
        ) == "Budget du mois dernier")
    }

    @Test func categoryAccessibilityHelpersUseEnglishBundleForEveryArgumentShape() {
        let locale = Locale(identifier: "en_US")
        #expect(BudgetCategoryAccessibility.details(category: "Groceries", locale: locale, bundle: actualiBundle) == "Details for Groceries")
        #expect(BudgetCategoryAccessibility.editBudget(category: "Groceries", locale: locale, bundle: actualiBundle) == "Edit budgeted amount for Groceries")
        #expect(BudgetCategoryAccessibility.monthTransactions(category: "Groceries", month: "September 2026", locale: locale, bundle: actualiBundle) == "Transactions for Groceries in September 2026")
        #expect(BudgetCategoryAccessibility.balanceAction(category: "Groceries", isOverspent: true, locale: locale, bundle: actualiBundle) == "Cover overspending for Groceries")
        #expect(BudgetCategoryAccessibility.balanceAction(category: "Groceries", isOverspent: false, locale: locale, bundle: actualiBundle) == "Move money from Groceries")
        #expect(BudgetCategoryAccessibility.visibility(isHidden: true, locale: locale, bundle: actualiBundle) == "Show")
        #expect(BudgetCategoryAccessibility.visibility(isHidden: false, locale: locale, bundle: actualiBundle) == "Hide")
        #expect(BudgetCategoryAccessibility.contextMoveAction(isOverspent: true, locale: locale, bundle: actualiBundle) == "Cover Overspending")
        #expect(BudgetCategoryAccessibility.contextMoveAction(isOverspent: false, locale: locale, bundle: actualiBundle) == "Move Money")
        #expect(BudgetCategoryAccessibility.contextVisibility(isHidden: true, locale: locale, bundle: actualiBundle) == "Show Category")
        #expect(BudgetCategoryAccessibility.contextVisibility(isHidden: false, locale: locale, bundle: actualiBundle) == "Hide Category")
    }

    @Test func categoryAccessibilityHelpersUseFrenchBundleForEveryArgumentShape() {
        let locale = Locale(identifier: "fr_FR")
        #expect(BudgetCategoryAccessibility.details(category: "Courses", locale: locale, bundle: actualiBundle) == "Détails de Courses")
        #expect(BudgetCategoryAccessibility.editBudget(category: "Courses", locale: locale, bundle: actualiBundle) == "Modifier le montant budgété pour Courses")
        #expect(BudgetCategoryAccessibility.monthTransactions(category: "Courses", month: "septembre 2026", locale: locale, bundle: actualiBundle) == "Transactions de Courses en septembre 2026")
        #expect(BudgetCategoryAccessibility.balanceAction(category: "Courses", isOverspent: true, locale: locale, bundle: actualiBundle) == "Couvrir le dépassement de Courses")
        #expect(BudgetCategoryAccessibility.balanceAction(category: "Courses", isOverspent: false, locale: locale, bundle: actualiBundle) == "Déplacer de l'argent depuis Courses")
        #expect(BudgetCategoryAccessibility.visibility(isHidden: true, locale: locale, bundle: actualiBundle) == "Afficher")
        #expect(BudgetCategoryAccessibility.visibility(isHidden: false, locale: locale, bundle: actualiBundle) == "Masquer")
        #expect(BudgetCategoryAccessibility.contextMoveAction(isOverspent: true, locale: locale, bundle: actualiBundle) == "Couvrir les dépenses excessives")
        #expect(BudgetCategoryAccessibility.contextMoveAction(isOverspent: false, locale: locale, bundle: actualiBundle) == "Déplacer de l’argent")
        #expect(BudgetCategoryAccessibility.contextVisibility(isHidden: true, locale: locale, bundle: actualiBundle) == "Afficher la catégorie")
        #expect(BudgetCategoryAccessibility.contextVisibility(isHidden: false, locale: locale, bundle: actualiBundle) == "Masquer la catégorie")
    }

    @Test func incomeFallbackUsesRequestedLocale() {
        #expect(ReportStrings.text("Income", locale: Locale(identifier: "en_US"), bundle: actualiBundle) == "Income")
        #expect(ReportStrings.text("Income", locale: Locale(identifier: "fr_FR"), bundle: actualiBundle) == "Revenus")
    }

    @Test func transferCandidateLabelsUseRequestedLocaleAndGrammar() {
        let cases: [(String, String, String, String, String)] = [
            ("en_US", "Groceries", "$25.00", "Recommended: Groceries ($25.00)", "Groceries ($25.00)"),
            ("fr_FR", "Courses", "25,00 €", "Recommandé : Courses (25,00 €)", "Courses (25,00 €)"),
            ("de_DE", "Lebensmittel", "25,00 €", "Empfohlen: Lebensmittel (25,00 €)", "Lebensmittel (25,00 €)"),
            ("pt_BR", "Mercado", "R$ 25,00", "Recomendado: Mercado (R$ 25,00)", "Mercado (R$ 25,00)")
        ]

        for (identifier, categoryName, amount, recommended, ordinary) in cases {
            let locale = Locale(identifier: identifier)
            #expect(BudgetTransferLocalization.candidateLabel(categoryName: categoryName, amount: amount, isRecommended: true, locale: locale, bundle: actualiBundle) == recommended)
            #expect(BudgetTransferLocalization.candidateLabel(categoryName: categoryName, amount: amount, isRecommended: false, locale: locale, bundle: actualiBundle) == ordinary)
        }
    }
}
