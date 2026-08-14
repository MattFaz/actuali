import Foundation

/// Meta for the upstream `budget-analysis-card` widget (dashboard.ts
/// BudgetAnalysisWidget). `interval` is declared upstream but the spreadsheet
/// only ever computes monthly intervals; it is kept for round-tripping.
struct BudgetAnalysisMeta: Codable, Equatable {
    let name: String?
    let conditions: [WidgetRuleCondition]?
    let conditionsOp: String?
    let timeFrame: WidgetTimeFrame?
    let interval: String?   // "Daily" | "Weekly" | "Monthly" | "Yearly"
    let graphType: String?  // "Line" | "Bar"
    let showBalance: Bool?
    let balanceOnly: Bool?
    let showHiddenCategories: Bool?
}

/// One budget row. Integrator: fetch with
/// `SELECT month, category, amount FROM <table>` where `<table>` is
/// "zero_budgets" (envelope) or "reflect_budgets" (tracking), selected by the
/// budgetType synced pref the way `BudgetDatabase.budgetTable(_:)` already
/// does ('tracking' / legacy 'report' → reflect_budgets, else zero_budgets).
/// `month` is YYYYMM and `amount` integer cents, both stored as such.
struct BudgetAnalysisBudgetEntry: Equatable {
    let month: Int  // YYYYMM
    let categoryId: String
    let amountCents: Int
}

struct BudgetAnalysisIntervalPoint: Equatable {
    let month: Int                        // YYYYMM
    let budgetedCents: Int
    let spentCents: Int                   // negative for spending, as upstream
    let balanceCents: Int
    let overspendingAdjustmentCents: Int  // positive
}

struct BudgetAnalysisData: Equatable {
    enum GraphType: Equatable {
        case line, bar
    }

    let intervalData: [BudgetAnalysisIntervalPoint]
    let totalBudgetedCents: Int
    let totalSpentCents: Int
    let graphType: GraphType
    let showBalance: Bool
    let balanceOnly: Bool
}

/// Port of the webapp's budget-analysis-spreadsheet.ts at card fidelity.
/// Budget rows here carry no carryover flag, so the balance math uses
/// upstream's default (carryover off): positive category balances roll
/// forward, negative ones zero out and surface as the next month's
/// overspending adjustment.
enum BudgetAnalysisEngine {

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    static func compute(
        meta: BudgetAnalysisMeta?,
        transactions: [Transaction],
        budgets: [BudgetAnalysisBudgetEntry],
        categories: [Category],
        categoryGroups: [CategoryGroup],
        today: Date,
        context: ConditionsFilter.Context = .empty
    ) -> BudgetAnalysisData {
        let cal = calendar

        // Stored time frame, or the card's default sliding window of the
        // trailing six months (BudgetAnalysisCard.tsx).
        let startMonth: Int
        let endMonth: Int
        if let tf = meta?.timeFrame {
            let (start, end) = TimeFrame.resolve(tf, asOf: today)
            startMonth = yyyymm(from: start, calendar: cal)
            endMonth = yyyymm(from: end, calendar: cal)
        } else {
            endMonth = yyyymm(from: today, calendar: cal)
            startMonth = addMonths(endMonth, -5)
        }

        let graphType: BudgetAnalysisData.GraphType = meta?.graphType == "Line" ? .line : .bar
        let showBalance = meta?.showBalance ?? true
        let balanceOnly = meta?.balanceOnly ?? false
        guard startMonth <= endMonth else {
            return BudgetAnalysisData(
                intervalData: [], totalBudgetedCents: 0, totalSpentCents: 0,
                graphType: graphType, showBalance: showBalance, balanceOnly: balanceOnly
            )
        }

        // Base set mirrors upstream isBaseCategory: expense categories only;
        // hidden ones count only when showHiddenCategories.
        let showHidden = meta?.showHiddenCategories ?? false
        let base = categories.filter { !$0.isIncome && (showHidden || !$0.hidden) }
        let included = filterCategoriesByConditions(
            base,
            groups: categoryGroups,
            conditions: meta?.conditions,
            conditionsOp: meta?.conditionsOp
        )
        let includedIds = Set(included.map(\.id))

        // Bucket budgets and spending by month. Spending mirrors the
        // envelope sum-amount cells: on-budget transactions of the included
        // categories, amounts kept negative.
        var budgetedByMonth: [Int: [String: Int]] = [:]
        for entry in budgets where includedIds.contains(entry.categoryId) && entry.month <= endMonth {
            budgetedByMonth[entry.month, default: [:]][entry.categoryId, default: 0] += entry.amountCents
        }
        var spentByMonth: [Int: [String: Int]] = [:]
        for tx in transactions {
            guard !tx.tombstone,
                  let catId = tx.categoryId, includedIds.contains(catId),
                  !context.offBudgetAccountIds.contains(tx.accountId) else { continue }
            let month = tx.date / 100
            guard month <= endMonth else { continue }
            spentByMonth[month, default: [:]][catId, default: 0] += tx.amount
        }

        // Upstream seeds the running balance from the leftover cells of the
        // month before the range; replaying every earlier month we were given
        // produces the same per-category carryovers.
        let earliest = min(
            budgetedByMonth.keys.min() ?? startMonth,
            spentByMonth.keys.min() ?? startMonth,
            startMonth
        )

        var carried: [String: Int] = [:]  // category id → balance carried into the current month
        var overspendingFromPrevMonth = 0
        var intervalData: [BudgetAnalysisIntervalPoint] = []
        var totalBudgeted = 0
        var totalSpent = 0

        var month = earliest
        while month <= endMonth {
            // Upstream starts the display loop with a zero adjustment
            // regardless of pre-range overspending.
            if month == startMonth { overspendingFromPrevMonth = 0 }

            var budgeted = 0
            var spent = 0
            var runningBalance = 0
            var overspendingThisMonth = 0
            var carriedNext: [String: Int] = [:]

            for cat in included {
                let catBudgeted = budgetedByMonth[month]?[cat.id] ?? 0
                let catSpent = spentByMonth[month]?[cat.id] ?? 0
                let carriedIn = carried[cat.id] ?? 0
                let catBalance = catBudgeted + catSpent + carriedIn

                budgeted += catBudgeted
                spent += catSpent
                runningBalance += carriedIn

                if catBalance > 0 {
                    carriedNext[cat.id] = catBalance
                } else if catBalance < 0 {
                    overspendingThisMonth += catBalance
                }
            }

            if month >= startMonth {
                totalBudgeted += budgeted
                totalSpent += spent
                intervalData.append(BudgetAnalysisIntervalPoint(
                    month: month,
                    budgetedCents: budgeted,
                    spentCents: spent,
                    balanceCents: budgeted + spent + runningBalance,
                    overspendingAdjustmentCents: abs(overspendingFromPrevMonth)
                ))
            }

            carried = carriedNext
            overspendingFromPrevMonth = overspendingThisMonth
            month = addMonths(month, 1)
        }

        return BudgetAnalysisData(
            intervalData: intervalData,
            totalBudgetedCents: totalBudgeted,
            totalSpentCents: totalSpent,
            graphType: graphType,
            showBalance: showBalance,
            balanceOnly: balanceOnly
        )
    }

    // MARK: - Category condition filtering

    /// Port of budgetDataQuery.ts filterCategoriesByConditions: only
    /// category / category_group conditions narrow the set, and if any of
    /// them can't be safely interpreted, no filtering happens at all (better
    /// to be broad than to silently exclude data). Shared with SpendingEngine,
    /// mirroring upstream's import into getSpendingBudgetFilters.
    static func filterCategoriesByConditions(
        _ categories: [Category],
        groups: [CategoryGroup],
        conditions: [WidgetRuleCondition]?,
        conditionsOp: String?
    ) -> [Category] {
        let categoryConditions = (conditions ?? []).filter {
            $0.customName == nil && ($0.field == "category" || $0.field == "category_group")
        }
        guard !categoryConditions.isEmpty,
              categoryConditions.allSatisfy(isSupportedCategoryCondition) else {
            return categories
        }

        let groupNameById = Dictionary(groups.map { ($0.id, $0.name) },
                                       uniquingKeysWith: { first, _ in first })
        let isOr = (conditionsOp ?? "and").lowercased() == "or"
        return categories.filter { cat in
            isOr
                ? categoryConditions.contains { matches(cat, $0, groupNameById: groupNameById) }
                : categoryConditions.allSatisfy { matches(cat, $0, groupNameById: groupNameById) }
        }
    }

    /// Port of budgetDataQuery.ts isSupportedCategoryCondition.
    static func isSupportedCategoryCondition(_ cond: WidgetRuleCondition) -> Bool {
        switch cond.op {
        case "is", "isNot", "contains", "doesNotContain", "matches":
            return decodeString(cond.value) != nil
        case "oneOf", "notOneOf":
            return decodeStringArray(cond.value) != nil
        default:
            return false
        }
    }

    private static func matches(
        _ cat: Category,
        _ cond: WidgetRuleCondition,
        groupNameById: [String: String]
    ) -> Bool {
        let key = cond.field == "category_group" ? cat.groupId : cat.id
        // Text operators compare against the human-readable name, not the UUID.
        let text = cond.field == "category_group" ? (groupNameById[key] ?? key) : cat.name

        switch cond.op {
        case "is":
            return decodeString(cond.value) == key
        case "isNot":
            return decodeString(cond.value) != key
        case "oneOf":
            return decodeStringArray(cond.value)?.contains(key) ?? false
        case "notOneOf":
            return !(decodeStringArray(cond.value)?.contains(key) ?? false)
        case "contains":
            guard let value = decodeString(cond.value) else { return false }
            return text.lowercased().contains(value.lowercased())
        case "doesNotContain":
            guard let value = decodeString(cond.value) else { return false }
            return !text.lowercased().contains(value.lowercased())
        case "matches":
            guard let value = decodeString(cond.value), value.count <= 256,
                  let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        default:
            return true
        }
    }

    // MARK: - Helpers

    private static func decodeString(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        return try? JSONDecoder().decode(String.self, from: value.raw)
    }

    private static func decodeStringArray(_ value: AnyCodable?) -> [String]? {
        guard let value else { return nil }
        return try? JSONDecoder().decode([String].self, from: value.raw)
    }

    private static func yyyymm(from date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 0) * 100 + (c.month ?? 0)
    }

    private static func addMonths(_ yyyymm: Int, _ delta: Int) -> Int {
        let total = (yyyymm / 100) * 12 + (yyyymm % 100 - 1) + delta
        return (total / 12) * 100 + total % 12 + 1
    }
}
