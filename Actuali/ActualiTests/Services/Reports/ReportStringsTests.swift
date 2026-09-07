import Foundation
import Testing
@testable import Actuali

struct ReportStringsTests {
    private var appBundle: Bundle {
        Bundle(identifier: "com.mfazz.ActualiOS")!
    }

    @Test func fixedReportLabelsResolveForSupportedLocales() {
        let english = ReportStrings.text("This month", locale: Locale(identifier: "en_US"), bundle: appBundle)
        let french = ReportStrings.text("This month", locale: Locale(identifier: "fr_FR"), bundle: appBundle)
        let brazilianPortuguese = ReportStrings.text("This month", locale: Locale(identifier: "pt_BR"), bundle: appBundle)

        #expect(english == "This month")
        #expect(french == "Ce mois-ci")
        #expect(brazilianPortuguese == "Este mês")
    }

    @Test func summaryPercentageUsesInjectedFrenchLocale() {
        #expect(SummaryWidgetFormatting.percentage(27.15, locale: Locale(identifier: "fr_FR")) == "27,15\u{00A0}%")
    }

    @Test func interpolatedReportLabelsResolveAtLookupTime() {
        let english = ReportStrings.format(
            "Ending: %@", "$1,234", locale: Locale(identifier: "en_US"), bundle: appBundle)
        let french = ReportStrings.format(
            "Ending: %@", "$1,234", locale: Locale(identifier: "fr_FR"), bundle: appBundle)
        let brazilianPortuguese = ReportStrings.format(
            "Ending: %@", "$1,234", locale: Locale(identifier: "pt_BR"), bundle: appBundle)

        #expect(english == "Ending: $1,234")
        #expect(french == "Fin : $1,234")
        #expect(brazilianPortuguese == "Final: $1,234")
    }

        @Test func formatUsesRequestedLocaleForInterpolation() {
            let requestedLocale = Locale.current.language.languageCode?.identifier == "fr"
                ? Locale(identifier: "en_US")
                : Locale(identifier: "fr_FR")
            let french = ReportStrings.format(
                "%0.2f",
                1234.5,
                locale: requestedLocale,
                bundle: appBundle
            )

            #expect(french == (requestedLocale.language.languageCode?.identifier == "fr" ? "1\u{202F}234,50" : "1,234.50"))
        }

    @Test(arguments: [
        (0.0, "0 years", "0 an", "0 ano"),
        (1.0, "1 year", "1 an", "1 ano"),
        (2.0, "2 years", "2 ans", "2 anos"),
        (1.25, "1.25 years", "1,25 an", "1,25 ano")
    ])
    func yearsToRetireUsesRequestedLocale(
        years: Double, english: String, french: String, brazilianPortuguese: String
    ) {
        #expect(ReportStrings.yearsToRetire(
            years, locale: Locale(identifier: "en_US"), bundle: appBundle) == english)
        #expect(ReportStrings.yearsToRetire(
            years, locale: Locale(identifier: "fr_FR"), bundle: appBundle) == french)
        #expect(ReportStrings.yearsToRetire(
            years, locale: Locale(identifier: "pt_BR"), bundle: appBundle) == brazilianPortuguese)
    }

    @Test func overspentBadgeUsesRequestedLocaleAndPluralRules() {
        let expected = [
            Locale(identifier: "en_US"): ["", "1 overspent category", "2 overspent categories"],
            Locale(identifier: "fr_FR"): ["", "1 catégorie en dépassement", "2 catégories en dépassement"],
            Locale(identifier: "pt_BR"): ["", "1 categoria com excesso de gastos", "2 categorias com excesso de gastos"]
        ]

        for (locale, values) in expected {
            for (count, value) in values.enumerated() {
                #expect(MainTabView.overspentBadgeValue(
                    count: count, locale: locale, bundle: appBundle) == value)
            }
        }
    }

    @Test func reportComparisonDeltaChartAndSyntheticLabelsAreExact() {
        let locales = [
            (Locale(identifier: "en_US"), ["vs budget", "more spent", "Budgeted", "Off budget", "Uncategorized"]),
            (Locale(identifier: "fr_FR"), ["vs budget", "dépensé en plus", "Budgété", "Hors budget", "Sans catégorie"]),
            (Locale(identifier: "pt_BR"), ["vs. orçamento", "a mais gasto", "Orçado", "Fora do orçamento", "Sem categoria"])
        ]
        for (locale, expected) in locales {
            #expect(ReportStrings.text("vs budget", locale: locale, bundle: appBundle) == expected[0])
            #expect(ReportStrings.text("more spent", locale: locale, bundle: appBundle) == expected[1])
            #expect(ReportStrings.text("Budgeted", locale: locale, bundle: appBundle) == expected[2])
            #expect(ReportStrings.text("Off budget", locale: locale, bundle: appBundle) == expected[3])
            #expect(ReportStrings.text("Uncategorized", locale: locale, bundle: appBundle) == expected[4])
        }
    }

    @Test func userProvidedReportLabelsRemainUntouched() {
        let userLabel = "My custom groceries"
        #expect(userLabel == "My custom groceries")
        #expect(ReportStrings.text(userLabel, locale: Locale(identifier: "fr_FR"), bundle: appBundle) == userLabel)
    }

    @Test func widgetChartLabelsResolveForEnglishAndFrench() {
        let english = Locale(identifier: "en_US")
        let french = Locale(identifier: "fr_FR")

        #expect(ReportStrings.text("Month", locale: english, bundle: appBundle) == "Month")
        #expect(ReportStrings.text("Days", locale: english, bundle: appBundle) == "Days")
        #expect(ReportStrings.text("Age", locale: french, bundle: appBundle) == "Âge")
        #expect(ReportStrings.text("Median", locale: french, bundle: appBundle) == "Médiane")
        #expect(ReportStrings.localized("\(1) days", locale: french, bundle: appBundle) == "1 jour")
        #expect(ReportStrings.localized("\(2) days", locale: french, bundle: appBundle) == "2 jours")
    }

    @Test func countBearingReportLabelsUseCLDRBranchesForZeroOneAndTwo() {
        let locales = [
            (Locale(identifier: "en_US"), [
                ("0 days", "Imported 0 transactions", "Average Spent (0 Months)"),
                ("1 day", "Imported 1 transaction", "Average Spent (1 Month)"),
                ("2 days", "Imported 2 transactions", "Average Spent (2 Months)")
            ]),
            (Locale(identifier: "fr_FR"), [
                ("0 jour", "0 transaction importée", "Dépense moyenne (sur 0 mois)"),
                ("1 jour", "1 transaction importée", "Dépense moyenne (sur 1 mois)"),
                ("2 jours", "2 transactions importées", "Dépense moyenne (sur 2 mois)")
            ]),
            (Locale(identifier: "pt_BR"), [
                ("0 dia", "0 transação importada", "Gasto médio (em 0 mês)"),
                ("1 dia", "1 transação importada", "Gasto médio (em 1 mês)"),
                ("2 dias", "2 transações importadas", "Gasto médio (em 2 meses)")
            ])
        ]

        for (locale, expected) in locales {
            for (count, values) in expected.enumerated() {
                #expect(ReportStrings.localized("\(count) days", locale: locale, bundle: appBundle) == values.0)
                #expect(ReportStrings.localized("Imported \(count) transactions", locale: locale, bundle: appBundle) == values.1)
                #expect(CategoryBudgetDetailSheet.quickAssignTitle(
                    for: .averageSpent,
                    isTracking: false,
                    historyCount: count,
                    locale: locale,
                    bundle: appBundle
                ) == values.2)
            }
        }
    }

    @Test @MainActor func schedulePostNoticeUsesCLDRBranchesForZeroOneAndTwo() {
        let expected = [
            Locale(identifier: "en_US"): [
                "Posted 0 scheduled transactions",
                "Posted 1 scheduled transaction",
                "Posted 2 scheduled transactions"
            ],
            Locale(identifier: "fr_FR"): [
                "0 transaction planifiée publiée",
                "1 transaction planifiée publiée",
                "2 transactions planifiées publiées"
            ],
            Locale(identifier: "pt_BR"): [
                "0 transação agendada publicada",
                "1 transação agendada publicada",
                "2 transações agendadas publicadas"
            ]
        ]

        for (locale, values) in expected {
            for (count, value) in values.enumerated() {
                #expect(BudgetStore.schedulePostNoticeText(
                    count: count,
                    locale: locale,
                    bundle: appBundle
                ) == value)
            }
        }
    }

    @Test func calendarFormattingUsesRequestedLocale() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let calendarDate = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!

        #expect(CalendarWidgetFormatting.weekdaySymbols(
            locale: Locale(identifier: "en_US"), firstDayOfWeekIdx: 0) == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(CalendarWidgetFormatting.weekdaySymbols(
            locale: Locale(identifier: "fr_FR"), firstDayOfWeekIdx: 1) == ["L", "M", "M", "J", "V", "S", "D"])
        let expected = [
            ("en_US", "Jan 2024"),
            ("fr_FR", "janv. 2024"),
            ("pt_BR", "jan. de 2024"),
            ("de_DE", "Jan. 2024")
        ]
        for (identifier, title) in expected {
            #expect(CalendarWidgetFormatting.monthTitle(
                calendarDate, locale: Locale(identifier: identifier)) == title)
        }
        let buddhistLocaleTitle = CalendarWidgetFormatting.monthTitle(
            calendarDate,
            locale: Locale(identifier: "th_TH@calendar=buddhist")
        )
        #expect(buddhistLocaleTitle.contains("2024"))
        #expect(!buddhistLocaleTitle.contains("2567"))
    }
}
