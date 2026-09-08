import Foundation
import Testing
@testable import Actuali

struct BudgetAutomationsTests {

    private let appBundle = Bundle(identifier: "com.mfazz.ActualiOS")!

    private func parse(_ line: String) throws -> GoalTemplate {
        try GoalTemplateParser.parse(line)
    }

    // MARK: - Migration to editor entries

    @Test func simpleWithLimitSplitsIntoLimitAndFixed() throws {
        let simple = try parse("#template-2 50 up to 100 hold")
        let entries = BudgetAutomations.migrateToEntries([simple], schedules: [])
        #expect(entries.map(\.displayType) == [.limit, .fixed])
        #expect(entries[0].template.limit == .init(amount: 100, hold: true, period: .monthly, start: nil))
        #expect(entries[1].template.type == .periodic)
        #expect(entries[1].template.amount == 50)
        #expect(entries[1].template.period == .init(period: .month, amount: 1))
        #expect(entries[1].template.priority == 2)
    }

    @Test func limitOnlySimpleBecomesLimitPlusRefill() throws {
        let simple = try parse("#template up to 500")
        let entries = BudgetAutomations.migrateToEntries([simple], schedules: [])
        #expect(entries.map(\.displayType) == [.limit, .refill])
        #expect(entries[1].template.priority == 0)
    }

    @Test func periodicWithLimitSplitsOutTheLimit() throws {
        let periodic = try parse("#template 10 repeat every 2 weeks starting 2024-01-04 up to 60")
        let entries = BudgetAutomations.migrateToEntries([periodic], schedules: [])
        #expect(entries.map(\.displayType) == [.fixed, .limit])
        #expect(entries[0].template.limit == nil)
        #expect(entries[1].template.limit?.amount == 60)
    }

    @Test func scheduleEntryHydratesId() throws {
        let schedule = GoalScheduleInfo(
            id: "sched-1", name: "Rent", completed: false, amount: .fixed(-1000),
            dateCondition: nil)
        let entries = BudgetAutomations.migrateToEntries(
            [try parse("#template schedule Rent")], schedules: [schedule])
        #expect(entries.count == 1)
        #expect(entries[0].template.scheduleId == "sched-1")
        #expect(entries[0].template.name == "Rent")
    }

    @Test func noOpSimpleIsDropped() {
        var simple = GoalTemplate(type: .simple, directive: .template, priority: 0)
        simple.monthly = nil
        #expect(BudgetAutomations.migrateToEntries([simple], schedules: []).isEmpty)
    }

    @Test func goalAndRemainderPassThrough() throws {
        let entries = BudgetAutomations.migrateToEntries(
            [try parse("#goal 1000"), try parse("#template remainder 3")], schedules: [])
        #expect(entries.map(\.displayType) == [.goal, .remainder])
    }

    // MARK: - Type conversion

    @Test func convertKeepsDescription() {
        var entry = AutomationEntry(
            template: BudgetAutomations.defaultTemplate(for: .fixed), displayType: .fixed)
        entry.template.description = "note"
        let converted = BudgetAutomations.convert(entry, to: .percentage)
        #expect(converted.displayType == .percentage)
        #expect(converted.template.type == .percentage)
        #expect(converted.template.description == "note")
        #expect(converted.template.percent == 15)
    }

    @Test func earlySpendingToggleCarriesFields() throws {
        let by = try parse("#template 500 by 2025-12")
        let spend = BudgetAutomations.setEarlySpending(by, enabled: true)
        #expect(spend.type == .spend)
        #expect(spend.from == "2025-12")
        let back = BudgetAutomations.setEarlySpending(spend, enabled: false)
        #expect(back.type == .by)
        #expect(back.from == nil)
    }

    @Test func historicalModeToggleCarriesMonths() throws {
        let average = try parse("#template average 6 months")
        let copy = BudgetAutomations.setHistoricalMode(average, copyMode: true)
        #expect(copy.type == .copy)
        #expect(copy.lookBack == 6)
        let back = BudgetAutomations.setHistoricalMode(copy, copyMode: false)
        #expect(back.type == .average)
        #expect(back.numMonths == 6)
    }

    // MARK: - Sentences

    @Test func sentencesMatchWebWording() throws {
        func sentence(_ line: String) throws -> String {
            AutomationSentences.sentence(
                for: try parse(line),
                amount: { "$\(AutomationSentences.trimTrailingZeros($0))" },
                categoryName: { $0 == "cat-salary" ? "Salary" : nil },
                locale: Locale(identifier: "en_US"), bundle: appBundle)
        }
        #expect(try sentence("#template 100 repeat every week starting 2024-01-01")
            == "Budget $100 every 1 week")
        #expect(try sentence("#template 500 by 2025-12")
            == "Save $500 by Dec 2025")
        #expect(try sentence("#template 15% of all income")
            == "Budget 15% of total income this month")
        #expect(try sentence("#template schedule full Rent")
            == "Cover the occurrences of the schedule ‘Rent’ this month")
        #expect(try sentence("#template average 3 months")
            == "Budget the average of the last 3 complete months")
        #expect(try sentence("#template remainder 2")
            == "Share remaining funds to budget (weight 2)")
        #expect(try sentence("#goal 1000") == "Long-term goal of $1000")
    }

    @Test func sentenceUsesLocalizedPeriodUnits() throws {
        let template = try parse("#template 100 repeat every 2 weeks starting 2024-01-01")
        let sentence = AutomationSentences.sentence(
            for: template,
            amount: { "$\(AutomationSentences.trimTrailingZeros($0))" },
            categoryName: { _ in nil }, locale: Locale(identifier: "en_US"), bundle: appBundle)
        #expect(sentence.contains("2 weeks"))
    }

    @Test func countBearingSentencesUseCatalogPluralRules() throws {
        let expected: [String: (periodic: [String], copy: [String], average: [String])] = [
            "en_US": (
                ["Budget $100 every 0 months", "Budget $100 every 1 month", "Budget $100 every 2 months"],
                ["Budget the same amount as 1 month ago", "Budget the same amount as 2 months ago"],
                ["Budget the average of the last 1 complete month", "Budget the average of the last 2 complete months"]),
            "fr_FR": (
                ["Budgéter $100 chaque 0 mois", "Budgéter $100 chaque 1 mois", "Budgéter $100 tous les 2 mois"],
                ["Budgéter le même montant qu'il y a 1 mois", "Budgéter le même montant qu'il y a 2 mois"],
                ["Budgéter la moyenne du dernier 1 mois complet", "Budgéter la moyenne des 2 derniers mois complets"]),
            "pt_BR": (
                ["Orçar $100 a cada 0 mês", "Orçar $100 a cada 1 mês", "Orçar $100 a cada 2 meses"],
                ["Orçar o mesmo valor de 1 mês atrás", "Orçar o mesmo valor de 2 meses atrás"],
                ["Orçar a média do último 1 mês completo", "Orçar a média dos últimos 2 meses completos"])
        ]

        for localeIdentifier in ["en_US", "fr_FR", "pt_BR"] {
            let locale = Locale(identifier: localeIdentifier)
            func render(_ line: String) throws -> String {
                AutomationSentences.sentence(
                    for: try parse(line),
                    amount: { "$\(AutomationSentences.trimTrailingZeros($0))" },
                    categoryName: { _ in nil }, locale: locale, bundle: appBundle)
            }
            for count in 0...2 {
                let periodic = try render("#template 100 repeat every \(count) months starting 2024-01-01")
                #expect(periodic == expected[localeIdentifier]!.periodic[count], "\(localeIdentifier) periodic \(count): \(periodic)")
            }
            for (index, count) in [1, 2].enumerated() {
                let copy = try render("#template copy from \(count) months ago")
                let average = try render("#template average \(count) months")
                #expect(copy == expected[localeIdentifier]!.copy[index], "\(localeIdentifier) copy \(count): \(copy)")
                #expect(average == expected[localeIdentifier]!.average[index], "\(localeIdentifier) average \(count): \(average)")
            }
        }

        let repeatExpected = [
            "en_US": ["Save $100 by Dec 2025, repeating every 1 month", "Save $100 by Dec 2025, repeating every 2 months"],
            "fr_FR": ["Épargner $100 pour déc. 2025, tous les 1 mois", "Épargner $100 pour déc. 2025, tous les 2 mois"],
            "pt_BR": ["Poupar $100 até dez. 2025, repetindo a cada 1 mês", "Poupar $100 até dez. 2025, repetindo a cada 2 meses"]
        ]
        for localeIdentifier in ["en_US", "fr_FR", "pt_BR"] {
            let locale = Locale(identifier: localeIdentifier)
            for (index, count) in [1, 2].enumerated() {
                let template = try parse("#template 100 by 2025-12 repeat every \(count) months")
                #expect(AutomationSentences.sentence(
                    for: template, amount: { "$\(AutomationSentences.trimTrailingZeros($0))" },
                    categoryName: { _ in nil }, locale: locale, bundle: appBundle) == repeatExpected[localeIdentifier]![index])
            }
        }

        let spendExpected = [
            "en_US": [
                "Save $100 by Dec 2025, early spending from Mar 2025, repeating every 1 month",
                "Save $100 by Dec 2025, early spending from Mar 2025, repeating every 2 months"],
            "fr_FR": [
                "Épargner $100 pour déc. 2025, dépenses anticipées depuis mars 2025, tous les 1 mois",
                "Épargner $100 pour déc. 2025, dépenses anticipées depuis mars 2025, tous les 2 mois"],
            "pt_BR": [
                "Poupar $100 até dez. 2025, gastos antecipados a partir de mar. 2025, repetindo a cada 1 mês",
                "Poupar $100 até dez. 2025, gastos antecipados a partir de mar. 2025, repetindo a cada 2 meses"]
        ]
        for localeIdentifier in ["en_US", "fr_FR", "pt_BR"] {
            let locale = Locale(identifier: localeIdentifier)
            for (index, count) in [1, 2].enumerated() {
                let template = try parse("#template 100 by 2025-12 spend from 2025-03 repeat every \(count) months")
                #expect(AutomationSentences.sentence(
                    for: template, amount: { "$\(AutomationSentences.trimTrailingZeros($0))" },
                    categoryName: { _ in nil }, locale: locale, bundle: appBundle) == spendExpected[localeIdentifier]![index])
            }
        }
    }

    @Test func sentenceRendersLegacySimpleMonthlyBudget() {
        var template = GoalTemplate(type: .simple, directive: .template)
        template.monthly = 50
        let sentence = AutomationSentences.sentence(
            for: template,
            amount: { "$\(AutomationSentences.trimTrailingZeros($0))" },
            categoryName: { _ in nil }, locale: Locale(identifier: "en_US"), bundle: appBundle)
        #expect(sentence == "Budget $50 per month")
    }

    @Test func zeroSimpleMonthlyBudgetMigratesToZeroPeriodicEntry() throws {
        let simple = try parse("#template 0")
        let entries = BudgetAutomations.migrateToEntries([simple], schedules: [])
        #expect(entries.count == 1)
        #expect(entries[0].displayType == .fixed)
        #expect(entries[0].template.type == .periodic)
        #expect(entries[0].template.amount == 0)
        #expect(entries[0].template.period == .init(period: .month, amount: 1))
    }

    @Test func sentenceRendersErrorTemplateSeparately() {
        var template = GoalTemplate(type: .error, directive: .error)
        template.error = "Bad template"
        let sentence = AutomationSentences.sentence(
            for: template,
            amount: { "$\(AutomationSentences.trimTrailingZeros($0))" },
            categoryName: { _ in nil }, locale: Locale(identifier: "en_US"), bundle: appBundle)
        #expect(sentence == "Invalid automation: Bad template")

        template.error = nil
        template.line = nil
        #expect(AutomationSentences.sentence(
            for: template,
            amount: { "$\(AutomationSentences.trimTrailingZeros($0))" },
            categoryName: { _ in nil }, locale: Locale(identifier: "en_US"), bundle: appBundle) == "Invalid automation: error")
    }

    @Test(arguments: ["en_US", "fr_FR", "pt_BR"])
    func simpleAndErrorBranchesAcceptExplicitLocale(localeIdentifier: String) {
        var simple = GoalTemplate(type: .simple, directive: .template)
        simple.monthly = 0
        var error = GoalTemplate(type: .error, directive: .error)
        error.error = "Bad template"
        let locale = Locale(identifier: localeIdentifier)
        let amount: (Double) -> String = { "$\(AutomationSentences.trimTrailingZeros($0))" }
        #expect(AutomationSentences.sentence(
            for: simple, amount: amount, categoryName: { _ in nil }, locale: locale).contains("0"))
        #expect(AutomationSentences.sentence(
            for: error, amount: amount, categoryName: { _ in nil }, locale: locale).contains("Bad template"))
    }

    // MARK: - Note rendering (unparse) round trip

    @Test func renderedNoteLinesReparseToTheSameTemplates() throws {
        let lines = [
            "#template-2 500 by 2025-12 spend from 2025-03 repeat every 2 years",
            "#template 100 repeat every 2 weeks starting 2024-01-01",
            "#template schedule full Rent [increase 5%]",
            "#template remainder 3",
            "#template average 4 months [decrease 10]",
            "#template copy from 3 months ago",
            "#goal 1000",
        ]
        let templates = try lines.map(parse)
        let rendered = AutomationSentences.renderNoteTemplates(templates)
        let reparsed = try rendered.components(separatedBy: "\n").map(parse)
        #expect(reparsed == templates)
    }

    @Test func refillMergesIntoLimitLine() throws {
        var limit = GoalTemplate(type: .limit, directive: .template, priority: nil)
        limit.limit = .init(amount: 150, hold: true, period: .monthly, start: nil)
        let refill = GoalTemplate(type: .refill, directive: .template, priority: 2)
        let rendered = AutomationSentences.renderNoteTemplates([limit, refill])
        #expect(rendered == "#template-2 up to 150 hold")
        // Round trip: the merged line parses as a limit-only simple, which
        // migrates back to limit + refill.
        let reparsed = try parse(rendered)
        let entries = BudgetAutomations.migrateToEntries([reparsed], schedules: [])
        #expect(entries.map(\.displayType) == [.limit, .refill])
        #expect(entries[1].template.priority == 2)
    }

    @Test func percentageNoteLineUsesCategoryName() throws {
        var template = try parse("#template 10% of Salary")
        template.category = "cat-salary"
        let rendered = AutomationSentences.renderNoteTemplates([template]) {
            $0 == "cat-salary" ? "Salary" : nil
        }
        #expect(rendered == "#template 10% of Salary")
    }

    @Test func mergeIntoNoteSkipsExistingLines() {
        let merged = AutomationSentences.mergeIntoNote(
            existingNote: "some words\n#template 50",
            rendered: "#template 50\n#goal 100")
        #expect(merged == "some words\n#template 50\n\nExport from automations UI:\n#goal 100")

        let unchanged = AutomationSentences.mergeIntoNote(
            existingNote: "keep\n#template 50", rendered: "#template 50")
        #expect(unchanged == "keep\n#template 50")
    }
}
