import Foundation
import Testing
@testable import Actuali

struct BudgetViewTests {
    private var appBundle: Bundle {
        .main
    }

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

    // MARK: - Hide Income Group

    private func incomeMonth() -> BudgetMonth {
        var month = BudgetMonth(month: "2026-10", categoryBudgets: [])
        month.incomeCategories = [
            IncomeCategory(month: "2026-10", categoryId: "salary", categoryName: "Salary", groupName: "Income", sortOrder: 0, budgeted: 0, received: 300_000),
        ]
        month.hiddenIncomeCategories = [
            IncomeCategory(month: "2026-10", categoryId: "old", categoryName: "Old", groupName: "Income", sortOrder: 1, budgeted: 0, received: 0, hidden: true),
        ]
        return month
    }

    @Test func incomeRowsShowWhenGroupIsNotHidden() {
        let rows = BudgetView.displayedIncomeCategories(in: incomeMonth(), showHidden: false, hideIncomeGroup: false)
        #expect(rows.map(\.categoryId) == ["salary"])
    }

    @Test func incomeRowsIncludeHiddenCategoriesWhenRequested() {
        let rows = BudgetView.displayedIncomeCategories(in: incomeMonth(), showHidden: true, hideIncomeGroup: false)
        #expect(rows.map(\.categoryId) == ["salary", "old"])
    }

    @Test func hidingTheIncomeGroupRemovesEveryIncomeRow() {
        #expect(BudgetView.displayedIncomeCategories(in: incomeMonth(), showHidden: false, hideIncomeGroup: true).isEmpty)
        #expect(BudgetView.displayedIncomeCategories(in: incomeMonth(), showHidden: true, hideIncomeGroup: true).isEmpty)
    }

    // MARK: - Group template scope

    private func groupCategory(_ id: String, group: String, available: Int, hidden: Bool = false) -> CategoryBudget {
        CategoryBudget(
            month: "2026-10", categoryId: id, categoryName: id,
            groupId: group, groupName: group, groupSortOrder: 0, categorySortOrder: 0,
            budgeted: 0, spent: 0, available: available, carryover: 0, hidden: hidden
        )
    }

    @Test func groupTemplateRunCoversRowsTheTableFiltersOut() {
        // "Hide Spent Categories" drops the zero-available row from the table,
        // but that row is the one that needs its template.
        var month = BudgetMonth(month: "2026-10", categoryBudgets: [
            groupCategory("rent", group: "bills", available: 0),
            groupCategory("power", group: "bills", available: 500),
            groupCategory("games", group: "fun", available: 0),
        ])
        month.hiddenCategoryBudgets = [groupCategory("old", group: "bills", available: 0, hidden: true)]

        #expect(BudgetView.groupTemplateCategoryIds(groupId: "bills", in: month) == ["rent", "power", "old"])
    }

    // MARK: - Month note (GH #567)

    @Test func monthNoteOffersTheNoteReadForTheSelectedMonth() {
        let note = EntityNote(supported: true, text: "Holiday month")

        #expect(BudgetView.monthNote(note, loadedFor: "2026-09", selectedMonth: "2026-09") == note)
    }

    /// Right after a month change the previous month's note is still in
    /// state; offering it would let a save overwrite the new month's note.
    @Test func monthNoteHidesAnotherMonthsNote() {
        let note = EntityNote(supported: true, text: "Holiday month")

        #expect(BudgetView.monthNote(note, loadedFor: "2026-08", selectedMonth: "2026-09") == .unsupported)
        #expect(BudgetView.monthNote(note, loadedFor: nil, selectedMonth: "2026-09") == .unsupported)
    }

    @Test func monthNoteStaysUnsupportedWithoutANotesTable() {
        #expect(BudgetView.monthNote(.unsupported, loadedFor: "2026-09", selectedMonth: "2026-09") == .unsupported)
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

    @Test func progressBarVisibilityIsLocalized() {
        let expectations = [
            ("en_US", "Show progress bar", "Hide progress bar"),
            ("fr_FR", "Afficher la barre de progression", "Masquer la barre de progression"),
        ]

        for (identifier, show, hide) in expectations {
            let locale = Locale(identifier: identifier)
            #expect(BudgetCategoryAccessibility.progressBarVisibility(isHidden: true, locale: locale, bundle: actualiBundle) == show)
            #expect(BudgetCategoryAccessibility.progressBarVisibility(isHidden: false, locale: locale, bundle: actualiBundle) == hide)
        }
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

    @Test(arguments: [
        ("en_US", "Groceries", "$25.00", "Recommended: Groceries ($25.00)", "Groceries ($25.00)"),
        ("fr_FR", "Courses", "25,00 €", "Recommandé : Courses (25,00 €)", "Courses (25,00 €)"),
        ("de_DE", "Lebensmittel", "25,00 €", "Empfohlen: Lebensmittel (25,00 €)", "Lebensmittel (25,00 €)"),
        ("pt_BR", "Mercado", "R$ 25,00", "Recomendado: Mercado (R$ 25,00)", "Mercado (R$ 25,00)"),
    ])
    func transferCandidateLabelsUseRequestedLocaleAndGrammar(
        identifier: String, categoryName: String, amount: String, recommended: String, ordinary: String
    ) {
        let locale = Locale(identifier: identifier)
        #expect(BudgetTransferLocalization.candidateLabel(categoryName: categoryName, amount: amount, isRecommended: true, locale: locale, bundle: actualiBundle) == recommended)
        #expect(BudgetTransferLocalization.candidateLabel(categoryName: categoryName, amount: amount, isRecommended: false, locale: locale, bundle: actualiBundle) == ordinary)
    }

    @Test func templateAlertMonthRunReportsUpToDateAsSuccess() {
        let alert = BudgetView.templateAlert(
            .upToDate,
            locale: Locale(identifier: "en_US"),
            bundle: appBundle
        )

        #expect(alert.title == "Templates Applied")
        #expect(alert.message == "All templates are up to date.")
    }

    /// A single-category run on a templateless category must not read as a
    /// month-wide success — GH #577 review.
    @Test func templateAlertSingleCategoryUpToDateNamesTheCategory() {
        let alert = BudgetView.templateAlert(
            .upToDate,
            singleCategory: true,
            locale: Locale(identifier: "en_US"),
            bundle: appBundle
        )

        #expect(alert.title == "Apply Budget Template")
        #expect(alert.message == "No templates to apply for this category.")
    }

    @Test func templateAlertAppliedAndFailureCases() {
        let applied = BudgetView.templateAlert(
            .applied(3),
            singleCategory: true,
            locale: Locale(identifier: "en_US"),
            bundle: appBundle
        )
        #expect(applied.title == "Templates Applied")
        #expect(applied.message == "Successfully applied templates to 3 categories.")

        let failed = BudgetView.templateAlert(
            .failed("sync unavailable"),
            locale: Locale(identifier: "en_US"),
            bundle: appBundle
        )
        #expect(failed.title == "Template Error")
        #expect(failed.message == "sync unavailable")
    }
}
