import Foundation

// MARK: - Meta

/// Mirrors upstream `SankeyWidget['meta']` (sankey-card).
struct SankeyMeta: Codable, Equatable {
    let name: String?
    let conditions: [WidgetRuleCondition]?
    let conditionsOp: String?
    let timeFrame: WidgetTimeFrame?
    let mode: String?           // "budgeted" | "spent"; nil = "spent"
    let topNcategories: Int?
    let categorySort: String?   // "per-group" | "global" | "budget-order"
    let showPercentages: Bool?
    let groupAccounts: Bool?
    let layerFrom: String?      // SankeyLayer raw value
    let layerTo: String?
}

// MARK: - Layers

/// Upstream `GraphLayers`; case order is GRAPH_LAYER_ORDER.
enum SankeyLayer: String, CaseIterable, Equatable {
    case incomePayee = "payee"
    case incomeCategory = "income_category"
    case account
    case budget
    case categoryGroup = "category_group"
    case category

    var orderIndex: Int { Self.allCases.firstIndex(of: self)! }
}

enum SankeySortMode: String {
    case perGroup = "per-group"
    case global
    case budgetOrder = "budget-order"
}

// MARK: - Output

struct SankeyData: Equatable {
    struct Node: Equatable {
        let key: String
        let name: String
        let percentageLabel: String
        let layer: SankeyLayer
        let isNegative: Bool

        var isHidden: Bool { key.hasSuffix("__HIDDEN") }
    }
    struct Link: Equatable {
        let source: Int
        let target: Int
        let value: Int  // cents; hidden layout-scaffolding links carry -1
    }

    let nodes: [Node]
    let links: [Link]
    let showPercentages: Bool

    static let empty = SankeyData(nodes: [], links: [], showPercentages: false)
}

// MARK: - Graph

/// Insertion-ordered directed graph mirroring upstream's `Graph` (a JS Map;
/// Map iteration order is insertion order, which the sort/layout relies on).
struct SankeyGraph {
    struct Node {
        var type: SankeyLayer
        var name: String?
        var isNegative: Bool = false
        var percentageLabel: String?
        var toOrder: [String] = []
        var toValues: [String: Int] = [:]

        var hasChild: Bool { !toOrder.isEmpty }
    }

    private(set) var order: [String] = []
    var nodes: [String: Node] = [:]

    var keys: [String] { order }

    subscript(key: String) -> Node? { nodes[key] }

    mutating func addNode(_ key: String, type: SankeyLayer, name: String?, isNegative: Bool = false) {
        guard nodes[key] == nil else { return }
        nodes[key] = Node(type: type, name: name, isNegative: isNegative)
        order.append(key)
    }

    mutating func addValueToLink(from: String, to: String, value: Int) {
        guard var node = nodes[from] else { return }
        if node.toValues[to] == nil { node.toOrder.append(to) }
        node.toValues[to] = (node.toValues[to] ?? 0) + value
        nodes[from] = node
    }

    mutating func deleteLink(from: String, to: String) {
        guard var node = nodes[from] else { return }
        node.toValues[to] = nil
        node.toOrder.removeAll { $0 == to }
        nodes[from] = node
    }

    mutating func delete(_ key: String) {
        nodes[key] = nil
        order.removeAll { $0 == key }
    }

    mutating func reorder(_ newOrder: [String]) { order = newOrder }

    func links(from key: String) -> [(to: String, value: Int)] {
        guard let node = nodes[key] else { return [] }
        return node.toOrder.map { ($0, node.toValues[$0] ?? 0) }
    }
}

// MARK: - Inputs

/// Upstream `CategoryEntry`. Spent mode stores `value` as abs(cents);
/// budgeted mode keeps the sign (matching upstream, whose createBudgetGraph
/// branches on the raw signed value).
struct SankeyCategoryEntry: Equatable {
    let categoryGroup: String
    let categoryGroupId: String
    let category: String
    let categoryId: String
    let value: Int
    let isIncome: Bool
    let isNegative: Bool
    var accountName: String? = nil
    var accountId: String? = nil
    var payeeName: String? = nil
    var payeeId: String? = nil
}

/// Budget-mode input. INTEGRATOR WIRING: `entries` come from
/// zero_budgets/reflect_budgets rows (month YYYYMM, category, amount cents).
/// The envelope aggregates mirror upstream `api/budget-month`:
/// - `toBudgetCents`: "to budget" of the range's LAST month
/// - `fromPreviousMonthCents`: fromLastMonth of the range's FIRST month
/// - `lastMonthOverspentCents`: sum of lastMonthOverspent across the range
/// - `forNextMonthCents`: nextMonth(end).fromLastMonth - toBudget
/// Leaving them 0 simply omits those flows (zero links are cleaned up).
struct SankeyBudgetInput: Equatable {
    struct Entry: Equatable {
        let month: Int  // YYYYMM
        let categoryId: String
        let amountCents: Int
    }
    var entries: [Entry] = []
    var toBudgetCents: Int = 0
    var fromPreviousMonthCents: Int = 0
    var lastMonthOverspentCents: Int = 0
    var forNextMonthCents: Int = 0
}

// MARK: - Engine

/// Port of the webapp's sankey-spreadsheet.ts at dashboard-card fidelity.
/// Deliberate cuts vs upstream: no tooltip info, no colors (the view derives
/// them), i18n labels resolved inline at node creation.
enum SankeyEngine {

    enum SpecialKey {
        static let toBudget = "to_budget"
        static let budgeted = "budgeted"
        static let lastMonthOverspent = "last_month_overspent"
        static let forNextMonth = "for_next_month"
        static let fromPrevMonth = "from_previous_month"
        static let availableIncome = "available_income"
        static let allAccounts = "all_income"
        static let otherSuffix = "__OTHER_BUCKET"
        static let hiddenSuffix = "__HIDDEN"
        static let negativeSuffix = "__NEGATIVE"
        // Upstream builds this from Object.values(SpecialNodeKeys), which
        // includes the literal suffix strings.
        static let structural: Set<String> = [
            toBudget, budgeted, lastMonthOverspent, forNextMonth, fromPrevMonth,
            availableIncome, allAccounts, otherSuffix, hiddenSuffix, negativeSuffix
        ]
    }

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    // MARK: Compute

    /// Account display names come from `context.accountNames` (the same map
    /// the conditions filter uses); missing entries fall back to the id so
    /// the card still renders. `maxNodesPerLayer` mirrors the card's
    /// height-based cap (upstream topNNodes: 35px per node, ~6 at card height)
    /// and is min'd with `meta.topNcategories ?? 15` like SankeyCard.tsx.
    static func compute(
        meta: SankeyMeta?,
        transactions: [Transaction],
        categoryGroups: [CategoryGroup],
        budget: SankeyBudgetInput? = nil,
        today: Date,
        context: ConditionsFilter.Context = .empty,
        maxNodesPerLayer: Int = 6
    ) -> SankeyData {
        var (start, end) = TimeFrame.resolve(meta?.timeFrame, asOf: today)
        // Upstream queries firstDayOfMonth(start)..lastDayOfMonth(end).
        start = monthStart(of: start)
        end = endOfMonth(monthStart(of: end))
        let startYMD = ymdInt(from: start)
        let endYMD = ymdInt(from: end)

        let isBudgeted = meta?.mode == "budgeted"
        // AQL `transactions` defaults to inline splits: children shown,
        // parents excluded.
        let live = transactions.filter {
            !$0.tombstone && !$0.isParent && $0.date >= startYMD && $0.date <= endYMD
        }

        let graph: SankeyGraph
        if isBudgeted {
            let entries = budgetEntries(
                categoryGroups: categoryGroups,
                conditions: meta?.conditions,
                conditionsOp: meta?.conditionsOp,
                budget: budget ?? SankeyBudgetInput(),
                transactions: live,
                months: monthsInRange(start: start, end: end)
            )
            graph = createBudgetGraph(
                entries,
                budget: budget ?? SankeyBudgetInput(),
                startMonth: monthLabel(start),
                endMonth: monthLabel(end)
            )
        } else {
            let entries = transactionEntries(
                categoryGroups: categoryGroups,
                transactions: live,
                conditions: meta?.conditions,
                conditionsOp: meta?.conditionsOp,
                groupAccounts: meta?.groupAccounts ?? false,
                context: context
            )
            graph = createTransactionsGraph(entries)
        }

        let topN = min(meta?.topNcategories ?? 15, maxNodesPerLayer)
        let sort = SankeySortMode(rawValue: meta?.categorySort ?? "") ?? .perGroup

        let layerFrom: SankeyLayer
        let layerTo: SankeyLayer
        if let f = meta?.layerFrom.flatMap(SankeyLayer.init(rawValue:)),
           let t = meta?.layerTo.flatMap(SankeyLayer.init(rawValue:)) {
            layerFrom = f
            layerTo = t
        } else {
            // Upstream getDefaultLayerRange(mode).
            layerFrom = isBudgeted ? .incomeCategory : .incomePayee
            layerTo = .category
        }

        return buildSankeyData(
            graph,
            topN: topN,
            categoryGroups: categoryGroups,
            categorySort: sort,
            layerFrom: layerFrom,
            layerTo: layerTo,
            showPercentages: meta?.showPercentages ?? false
        )
    }

    // MARK: Entry building (spent)

    /// Upstream fetchCategoryData: per category, transactions grouped by
    /// account (expense) or account+payee (income), summed.
    static func transactionEntries(
        categoryGroups: [CategoryGroup],
        transactions: [Transaction],
        conditions: [WidgetRuleCondition]?,
        conditionsOp: String?,
        groupAccounts: Bool,
        context: ConditionsFilter.Context
    ) -> [SankeyCategoryEntry] {
        let filtered = transactions.filter {
            ConditionsFilter.matches(transaction: $0, conditions: conditions, op: conditionsOp, context: context)
        }

        var entries: [SankeyCategoryEntry] = []
        for group in categoryGroups {
            for cat in group.categories {
                let txs = filtered.filter { $0.categoryId == cat.id }
                var bucketOrder: [String] = []
                var buckets: [String: (accountId: String, payeeId: String?, payeeName: String?, sum: Int)] = [:]
                for tx in txs {
                    let key = group.isIncome ? tx.accountId + "|" + (tx.payeeId ?? "") : tx.accountId
                    if buckets[key] == nil {
                        bucketOrder.append(key)
                        buckets[key] = (
                            tx.accountId,
                            group.isIncome ? tx.payeeId : nil,
                            group.isIncome ? tx.payeeName : nil,
                            0
                        )
                    }
                    buckets[key]?.sum += tx.amount
                }
                for key in bucketOrder {
                    guard let b = buckets[key] else { continue }
                    entries.append(SankeyCategoryEntry(
                        categoryGroup: group.name,
                        categoryGroupId: group.id,
                        category: cat.name,
                        categoryId: cat.id,
                        value: abs(b.sum),
                        isIncome: group.isIncome,
                        isNegative: b.sum < 0,
                        accountName: context.accountNames[b.accountId] ?? b.accountId,
                        accountId: b.accountId,
                        payeeName: b.payeeName,
                        payeeId: b.payeeId
                    ))
                }
            }
        }

        if groupAccounts {
            entries = entries.map { entry in
                var e = entry
                if e.accountId?.isEmpty == false && e.accountName?.isEmpty == false {
                    e.accountId = SpecialKey.allAccounts
                    e.accountName = SpecialKey.allAccounts
                }
                return e
            }
        }
        return entries
    }

    static func createTransactionsGraph(_ categoryData: [SankeyCategoryEntry]) -> SankeyGraph {
        var graph = SankeyGraph()

        func addAccountNode(_ accountId: String, _ accountName: String) {
            graph.addNode(
                accountId,
                type: .account,
                name: accountId == SpecialKey.allAccounts ? "Income" : accountName
            )
        }

        for entry in categoryData {
            guard let accountId = entry.accountId, !accountId.isEmpty,
                  let accountName = entry.accountName, !accountName.isEmpty,
                  !entry.categoryId.isEmpty else { continue }
            // Upstream falls back `payeeName ?? category`; we also treat the
            // empty string as missing (upstream's AQL always yields '').
            let payeeOrCategory = (entry.payeeName?.isEmpty == false) ? entry.payeeName! : entry.category

            if entry.isIncome {
                if entry.isNegative {
                    // Account > (negative income shown as an outflow bucket)
                    addAccountNode(accountId, accountName)
                    let negKey = entry.categoryId + SpecialKey.negativeSuffix
                    graph.addNode(negKey, type: .categoryGroup, name: payeeOrCategory, isNegative: true)
                    graph.addValueToLink(from: accountId, to: negKey, value: entry.value)
                } else {
                    // Payee > Income category > Account
                    graph.addNode(entry.categoryId, type: .incomeCategory, name: entry.category)
                    addAccountNode(accountId, accountName)
                    graph.addValueToLink(from: entry.categoryId, to: accountId, value: entry.value)
                    if let payeeId = entry.payeeId, !payeeId.isEmpty {
                        graph.addNode(payeeId, type: .incomePayee, name: entry.payeeName)
                        graph.addValueToLink(from: payeeId, to: entry.categoryId, value: entry.value)
                    }
                }
            } else {
                if entry.isNegative {
                    // Account > Category group > Category
                    addAccountNode(accountId, accountName)
                    graph.addNode(entry.categoryGroupId, type: .categoryGroup, name: entry.categoryGroup)
                    graph.addNode(entry.categoryId, type: .category, name: entry.category)
                    graph.addValueToLink(from: accountId, to: entry.categoryGroupId, value: entry.value)
                    graph.addValueToLink(from: entry.categoryGroupId, to: entry.categoryId, value: entry.value)
                } else {
                    // Refund: Category (as income-side node) > Account
                    let negKey = entry.categoryId + SpecialKey.negativeSuffix
                    graph.addNode(negKey, type: .incomeCategory, name: payeeOrCategory)
                    addAccountNode(accountId, accountName)
                    graph.addValueToLink(from: negKey, to: accountId, value: entry.value)
                }
            }
        }
        return graph
    }

    // MARK: Entry building (budgeted)

    /// Income categories use "received" (sum of transactions in range, NOT
    /// filtered by conditions — upstream budget-month data is unconditioned);
    /// expense categories use budgeted amounts. Zero entries are dropped.
    static func budgetEntries(
        categoryGroups: [CategoryGroup],
        conditions: [WidgetRuleCondition]?,
        conditionsOp: String?,
        budget: SankeyBudgetInput,
        transactions: [Transaction],
        months: Set<Int>
    ) -> [SankeyCategoryEntry] {
        let filteredGroups = filterCategoryGroups(categoryGroups, conditions: conditions, conditionsOp: conditionsOp)

        var budgetedByCat: [String: Int] = [:]
        for entry in budget.entries where months.contains(entry.month) {
            budgetedByCat[entry.categoryId, default: 0] += entry.amountCents
        }

        var entries: [SankeyCategoryEntry] = []
        for group in filteredGroups {
            for cat in group.categories {
                let raw = group.isIncome
                    ? transactions.filter { $0.categoryId == cat.id }.reduce(0) { $0 + $1.amount }
                    : budgetedByCat[cat.id] ?? 0
                guard raw != 0 else { continue }
                entries.append(SankeyCategoryEntry(
                    categoryGroup: group.name,
                    categoryGroupId: group.id,
                    category: cat.name,
                    categoryId: cat.id,
                    value: raw,
                    isIncome: group.isIncome,
                    isNegative: raw < 0
                ))
            }
        }
        return entries
    }

    /// Upstream filterCategoryGroups: budget data is fetched unconditionally,
    /// so category/category_group conditions are applied manually.
    static func filterCategoryGroups(
        _ groups: [CategoryGroup],
        conditions: [WidgetRuleCondition]?,
        conditionsOp: String?
    ) -> [CategoryGroup] {
        let all = conditions ?? []
        let catConds = all.filter { $0.field == "category" }
        let groupConds = all.filter { $0.field == "category_group" }
        guard !catConds.isEmpty || !groupConds.isEmpty else { return groups }

        let isOr = (conditionsOp ?? "and").lowercased() == "or"

        func matches(_ catId: String, _ catName: String, _ groupId: String, _ groupName: String) -> Bool {
            let matchesCat = { (c: WidgetRuleCondition) in matchesStringCondition(id: catId, name: catName, condition: c) }
            let matchesGroup = { (c: WidgetRuleCondition) in matchesStringCondition(id: groupId, name: groupName, condition: c) }
            if isOr {
                return catConds.contains(where: matchesCat) || groupConds.contains(where: matchesGroup)
            }
            return (catConds.isEmpty || catConds.allSatisfy(matchesCat))
                && (groupConds.isEmpty || groupConds.allSatisfy(matchesGroup))
        }

        return groups
            .map { group -> CategoryGroup in
                var g = group
                g.categories = group.categories.filter { matches($0.id, $0.name, group.id, group.name) }
                return g
            }
            .filter { !$0.categories.isEmpty }
    }

    private static func matchesStringCondition(id: String, name: String, condition: WidgetRuleCondition) -> Bool {
        switch condition.op {
        case "is":
            return id == decodeString(condition.value)
        case "isNot":
            return id != decodeString(condition.value)
        case "oneOf":
            return decodeStringArray(condition.value)?.contains(id) ?? false
        case "notOneOf":
            return !(decodeStringArray(condition.value)?.contains(id) ?? false)
        case "contains":
            guard let value = decodeString(condition.value) else { return false }
            return name.lowercased().contains(value.lowercased())
        case "doesNotContain":
            guard let value = decodeString(condition.value) else { return false }
            return !name.lowercased().contains(value.lowercased())
        case "matches":
            guard let value = decodeString(condition.value), value.count <= 256 else { return false }
            // Upstream accepts "/pattern/" or a bare pattern, case-insensitive.
            var pattern = value
            if pattern.hasPrefix("/"), let lastSlash = pattern.lastIndex(of: "/"), lastSlash != pattern.startIndex {
                pattern = String(pattern[pattern.index(after: pattern.startIndex)..<lastSlash])
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        default:
            return false
        }
    }

    static func createBudgetGraph(
        _ categoryData: [SankeyCategoryEntry],
        budget: SankeyBudgetInput,
        startMonth: String,
        endMonth: String
    ) -> SankeyGraph {
        var graph = SankeyGraph()

        graph.addNode(SpecialKey.budgeted, type: .budget, name: "Budgeted")
        graph.addNode(SpecialKey.availableIncome, type: .account, name: "Available funds")

        for entry in categoryData {
            if entry.isIncome {
                // Income category > Available income
                graph.addNode(entry.categoryId, type: .incomeCategory, name: entry.category)
                graph.addValueToLink(from: entry.categoryId, to: SpecialKey.availableIncome, value: entry.value)
            } else if entry.value >= 0 {
                // Budgeted > Category group > Category
                graph.addNode(entry.categoryGroupId, type: .categoryGroup, name: entry.categoryGroup)
                graph.addNode(entry.categoryId, type: .category, name: entry.category)
                graph.addValueToLink(from: entry.categoryGroupId, to: entry.categoryId, value: entry.value)
                graph.addValueToLink(from: SpecialKey.budgeted, to: entry.categoryGroupId, value: entry.value)
                graph.addValueToLink(from: SpecialKey.availableIncome, to: SpecialKey.budgeted, value: entry.value)
            } else {
                // Negative budget: category feeds the budget pool
                graph.addNode(entry.categoryId, type: .account, name: "From \(entry.category)", isNegative: true)
                graph.addValueToLink(from: entry.categoryId, to: SpecialKey.budgeted, value: abs(entry.value))
                graph.addValueToLink(from: SpecialKey.availableIncome, to: SpecialKey.budgeted, value: entry.value)
            }
        }

        if budget.toBudgetCents > 0 {
            graph.addNode(SpecialKey.toBudget, type: .categoryGroup, name: "To budget")
            graph.addValueToLink(from: SpecialKey.availableIncome, to: SpecialKey.toBudget, value: budget.toBudgetCents)
        } else {
            graph.addNode(SpecialKey.toBudget, type: .account, name: "Overbudgeted", isNegative: true)
            graph.addValueToLink(from: SpecialKey.toBudget, to: SpecialKey.budgeted, value: abs(budget.toBudgetCents))
            graph.addValueToLink(from: SpecialKey.availableIncome, to: SpecialKey.budgeted, value: -abs(budget.toBudgetCents))
        }

        graph.addNode(SpecialKey.fromPrevMonth, type: .incomeCategory, name: "From \(shiftMonth(startMonth, by: -1))")
        graph.addValueToLink(from: SpecialKey.fromPrevMonth, to: SpecialKey.availableIncome, value: budget.fromPreviousMonthCents)
        graph.addNode(SpecialKey.forNextMonth, type: .budget, name: "For \(shiftMonth(endMonth, by: 1))")
        graph.addValueToLink(from: SpecialKey.availableIncome, to: SpecialKey.forNextMonth, value: budget.forNextMonthCents)
        graph.addNode(SpecialKey.lastMonthOverspent, type: .budget, name: "Overspent")
        graph.addValueToLink(from: SpecialKey.availableIncome, to: SpecialKey.lastMonthOverspent, value: abs(budget.lastMonthOverspentCents))

        return graph
    }

    // MARK: Pipeline (upstream buildSankeyData)

    static func buildSankeyData(
        _ baseGraph: SankeyGraph,
        topN: Int,
        categoryGroups: [CategoryGroup],
        categorySort: SankeySortMode,
        layerFrom: SankeyLayer,
        layerTo: SankeyLayer,
        showPercentages: Bool = false
    ) -> SankeyData {
        var graph = baseGraph  // value type; upstream clones
        groupOtherCategories(&graph, topN: topN, categorySort: categorySort)
        sortGraph(&graph, categorySort: categorySort, categoryGroups: categoryGroups)
        addPercentageLabels(&graph)
        cleanUpNodes(&graph)
        addHiddenNodes(&graph)
        filterGraphByLayers(&graph, from: layerFrom, to: layerTo)
        return convertToSankeyData(graph, showPercentages: showPercentages)
    }

    // MARK: Graph queries

    static func getLayer(_ graph: SankeyGraph, _ key: String) -> Int {
        let parents = graph.keys.filter { graph[$0]?.toValues[key] != nil }
        guard !parents.isEmpty else { return 0 }
        return 1 + parents.map { getLayer(graph, $0) }.max()!
    }

    static func getNodeValue(_ graph: SankeyGraph, _ key: String) -> Int {
        if getLayer(graph, key) == 0 {
            return graph[key]?.toValues.values.reduce(0, +) ?? 0
        }
        var value = 0
        for k in graph.keys {
            value += graph[k]?.toValues[key] ?? 0
        }
        // Root node masked behind hidden (-1) links
        if value < 0 {
            value = graph[key]?.toValues.values.reduce(0, +) ?? 0
        }
        return value
    }

    static func nodesInLayer(_ graph: SankeyGraph, _ layer: SankeyLayer) -> [String] {
        graph.keys.filter { graph[$0]?.type == layer }
    }

    static func hasParent(_ graph: SankeyGraph, _ key: String) -> Bool {
        graph.keys.contains { graph[$0]?.toValues[key] != nil }
    }

    static func getCategoryGroup(_ graph: SankeyGraph, _ key: String) -> String? {
        graph.keys.first { graph[$0]?.toValues[key] != nil && graph[$0]?.type == .categoryGroup }
    }

    // MARK: Other-bucket grouping

    static func groupOtherCategories(_ graph: inout SankeyGraph, topN: Int, categorySort: SankeySortMode) {
        func isGroupable(_ key: String) -> Bool {
            guard let node = graph[key] else { return false }
            return !key.hasSuffix(SpecialKey.otherSuffix)
                && !SpecialKey.structural.contains(key)
                && !node.isNegative
        }

        for layer in SankeyLayer.allCases {
            var ordinary = nodesInLayer(graph, layer).filter(isGroupable)
            var others = nodesInLayer(graph, layer).filter { $0.hasSuffix(SpecialKey.otherSuffix) }

            while ordinary.count + others.count > topN {
                // min(by:) keeps the first of equal elements, matching the
                // upstream strict `<` scan.
                guard let nodeToDelete = ordinary.min(by: { getNodeValue(graph, $0) < getNodeValue(graph, $1) }) else { break }
                moveToOther(&graph, nodeToDelete, globalOther: categorySort == .global)
                ordinary = nodesInLayer(graph, layer).filter(isGroupable)
                others = nodesInLayer(graph, layer).filter { $0.hasSuffix(SpecialKey.otherSuffix) }
            }
        }
    }

    static func moveToOther(_ graph: inout SankeyGraph, _ key: String, globalOther: Bool) {
        guard let nodeData = graph[key] else { return }

        let toNodes = nodeData.toOrder
        let fromNodes = graph.keys.filter { graph[$0]?.toValues[key] != nil }

        var otherKey = nodeData.type.rawValue + SpecialKey.otherSuffix
        if !globalOther {
            if nodeData.type == .category, let groupKey = getCategoryGroup(graph, key) {
                otherKey = groupKey + SpecialKey.otherSuffix
            } else if nodeData.type == .incomePayee,
                      let incomeCatKey = nodeData.toOrder.first(where: { graph[$0]?.type == .incomeCategory }) {
                otherKey = incomeCatKey + SpecialKey.otherSuffix
            }
        }

        graph.addNode(otherKey, type: nodeData.type, name: "Other")

        for fromKey in fromNodes {
            if let value = graph[fromKey]?.toValues[key] {
                graph.addValueToLink(from: fromKey, to: otherKey, value: value)
            }
        }
        for toKey in toNodes {
            if let value = graph[key]?.toValues[toKey] {
                graph.addValueToLink(from: otherKey, to: toKey, value: value)
            }
        }

        for toKey in toNodes { graph.deleteLink(from: key, to: toKey) }
        for fromKey in fromNodes { graph.deleteLink(from: fromKey, to: key) }
        graph.delete(key)
    }

    // MARK: Sorting

    static func sortGraph(_ graph: inout SankeyGraph, categorySort: SankeySortMode, categoryGroups: [CategoryGroup]) {
        let snapshot = graph

        // Stable value-descending sort (JS Array.sort is stable).
        func valueSortedKeys() -> [String] {
            snapshot.keys.enumerated().sorted { a, b in
                let va = getNodeValue(snapshot, a.element)
                let vb = getNodeValue(snapshot, b.element)
                return va == vb ? a.offset < b.offset : va > vb
            }.map(\.element)
        }

        func sortRelatedNodesAroundAnchors(
            _ entries: inout [String],
            anchorLayer: SankeyLayer,
            relatedLayer: SankeyLayer,
            placeAfter: Bool
        ) {
            for anchorKey in nodesInLayer(snapshot, anchorLayer) {
                guard let anchor = snapshot[anchorKey] else { continue }

                let relatedKeys: [String] = placeAfter
                    ? anchor.toOrder.filter { snapshot[$0]?.type == relatedLayer }
                    : snapshot.keys.filter { snapshot[$0]?.type == relatedLayer && snapshot[$0]?.toValues[anchorKey] != nil }

                let otherKey = anchorKey + SpecialKey.otherSuffix
                let relatedOtherKey: String? = snapshot[otherKey]?.type == relatedLayer ? otherKey : nil
                let orderedRelatedKeys = relatedKeys.filter { $0 != otherKey }

                let present = orderedRelatedKeys.filter { entries.contains($0) }
                let relatedEntries = present.enumerated().sorted { a, b in
                    let va = getNodeValue(snapshot, a.element)
                    let vb = getNodeValue(snapshot, b.element)
                    return va == vb ? a.offset < b.offset : va > vb
                }.map(\.element)

                let otherEntry: String? = relatedOtherKey.flatMap { entries.contains($0) ? $0 : nil }

                var keysToMove = Set(orderedRelatedKeys)
                if let relatedOtherKey { keysToMove.insert(relatedOtherKey) }
                var without = entries.filter { !keysToMove.contains($0) }
                guard let anchorIndex = without.firstIndex(of: anchorKey) else { continue }

                let insertionIndex = placeAfter ? anchorIndex + 1 : anchorIndex
                var nodesToInsert = relatedEntries
                if let otherEntry { nodesToInsert.append(otherEntry) }
                without.insert(contentsOf: nodesToInsert, at: insertionIndex)
                entries = without
            }
        }

        var entries: [String]
        switch categorySort {
        case .global:
            entries = valueSortedKeys()
            for key in entries.filter({ $0.hasSuffix(SpecialKey.otherSuffix) }) {
                moveNodeToEnd(&entries, key)
            }
        case .perGroup:
            entries = valueSortedKeys()
            sortRelatedNodesAroundAnchors(&entries, anchorLayer: .categoryGroup, relatedLayer: .category, placeAfter: true)
            sortRelatedNodesAroundAnchors(&entries, anchorLayer: .incomeCategory, relatedLayer: .incomePayee, placeAfter: false)
        case .budgetOrder:
            var used = Set<String>()
            entries = []
            for group in categoryGroups {
                if snapshot[group.id] != nil {
                    entries.append(group.id)
                    used.insert(group.id)
                }
                for cat in group.categories where snapshot[cat.id] != nil {
                    entries.append(cat.id)
                    used.insert(cat.id)
                }
                let otherKey = group.id + SpecialKey.otherSuffix
                if snapshot[otherKey] != nil {
                    entries.append(otherKey)
                    used.insert(otherKey)
                }
            }
            for key in snapshot.keys where !used.contains(key) {
                entries.append(key)
            }
        }

        // Pin certain nodes to the start/end of the graph.
        for key in entries.filter({ snapshot[$0]?.isNegative == true }) {
            moveNodeToStart(&entries, key)
        }
        if let toBudgetNode = snapshot[SpecialKey.toBudget] {
            if toBudgetNode.isNegative {
                moveNodeToStart(&entries, SpecialKey.toBudget)
            } else {
                moveNodeToEnd(&entries, SpecialKey.toBudget)
            }
        }
        moveNodeToEnd(&entries, SpecialKey.lastMonthOverspent)
        moveNodeToEnd(&entries, SpecialKey.forNextMonth)
        moveNodeToEnd(&entries, SpecialKey.fromPrevMonth)

        graph.reorder(entries)
    }

    static func moveNodeToEnd(_ entries: inout [String], _ key: String) {
        if let index = entries.firstIndex(of: key) {
            entries.append(entries.remove(at: index))
        }
    }

    static func moveNodeToStart(_ entries: inout [String], _ key: String) {
        if let index = entries.firstIndex(of: key) {
            entries.insert(entries.remove(at: index), at: 0)
        }
    }

    // MARK: Labels / cleanup

    static func addPercentageLabels(_ graph: inout SankeyGraph) {
        var layerSums: [SankeyLayer: Int] = [:]
        for key in graph.keys {
            guard let layer = graph[key]?.type else { continue }
            layerSums[layer, default: 0] += getNodeValue(graph, key)
        }
        for key in graph.keys {
            guard let node = graph[key] else { continue }
            let total = layerSums[node.type] ?? 1
            let percentage = total != 0 ? Double(getNodeValue(graph, key)) / Double(total) * 100 : 0
            graph.nodes[key]?.percentageLabel = String(format: "%.1f%%", percentage)
        }
    }

    static func cleanUpNodes(_ graph: inout SankeyGraph) {
        for key in graph.keys {
            for (to, value) in graph.links(from: key) where value == 0 {
                graph.deleteLink(from: key, to: to)
            }
        }
        var hasIncoming = Set<String>()
        for key in graph.keys {
            graph[key]?.toOrder.forEach { hasIncoming.insert($0) }
        }
        for key in graph.keys where graph[key]?.hasChild == false && !hasIncoming.contains(key) {
            graph.delete(key)
        }
    }

    // MARK: Hidden layout nodes

    /// Nodes whose parents/children sit in different layers than their peers
    /// would land in the wrong column; invisible -1 chains pin them in place.
    static func addHiddenNodes(_ graph: inout SankeyGraph) {
        var nodesByType: [SankeyLayer: [String]] = [:]
        for key in graph.keys {
            guard let type = graph[key]?.type else { continue }
            nodesByType[type, default: []].append(key)
        }

        var typeHasParent: [SankeyLayer: Bool] = [:]
        var typeHasChild: [SankeyLayer: Bool] = [:]
        for (type, keys) in nodesByType {
            typeHasParent[type] = keys.contains { hasParent(graph, $0) }
            typeHasChild[type] = keys.contains { graph[$0]?.hasChild == true }
        }

        let activeLayerOrder = SankeyLayer.allCases.filter { !(nodesByType[$0] ?? []).isEmpty }
        var layerIndex: [SankeyLayer: Int] = [:]
        for (index, layer) in activeLayerOrder.enumerated() {
            layerIndex[layer] = index
        }

        func addHiddenParentChain(_ key: String, _ type: SankeyLayer) {
            guard let typeIndex = layerIndex[type], typeIndex > 0 else { return }
            var childKey = key
            for i in stride(from: typeIndex - 1, through: 0, by: -1) {
                let parentType = activeLayerOrder[i]
                let parentKey = "\(key)_\(parentType.rawValue)\(SpecialKey.hiddenSuffix)"
                graph.addNode(parentKey, type: parentType, name: "")
                graph.addValueToLink(from: parentKey, to: childKey, value: -1)
                childKey = parentKey
            }
        }

        func addHiddenChildChain(_ key: String, _ type: SankeyLayer) {
            guard let typeIndex = layerIndex[type], typeIndex < activeLayerOrder.count - 1 else { return }
            var parentKey = key
            for i in (typeIndex + 1)..<activeLayerOrder.count {
                let childType = activeLayerOrder[i]
                let childKey = "\(key)_\(childType.rawValue)\(SpecialKey.hiddenSuffix)"
                graph.addNode(childKey, type: childType, name: "")
                graph.addValueToLink(from: parentKey, to: childKey, value: -1)
                parentKey = childKey
            }
        }

        for layer in SankeyLayer.allCases {
            for key in nodesByType[layer] ?? [] {
                let nodeHasParent = hasParent(graph, key)
                let nodeHasChild = graph[key]?.hasChild == true
                if !nodeHasParent && typeHasParent[layer] == true {
                    addHiddenParentChain(key, layer)
                }
                if !nodeHasChild && typeHasChild[layer] == true {
                    addHiddenChildChain(key, layer)
                }
            }
        }
    }

    static func filterGraphByLayers(_ graph: inout SankeyGraph, from: SankeyLayer, to: SankeyLayer) {
        let fromIndex = from.orderIndex
        let toIndex = to.orderIndex
        for key in graph.keys {
            guard let index = graph[key]?.type.orderIndex else { continue }
            if index < fromIndex || index > toIndex {
                graph.delete(key)
            }
        }
    }

    // MARK: Conversion

    static func convertToSankeyData(_ graph: SankeyGraph, showPercentages: Bool = false) -> SankeyData {
        let keys = graph.keys
        var indexByKey: [String: Int] = [:]
        for (index, key) in keys.enumerated() {
            indexByKey[key] = index
        }

        let nodes = keys.map { key -> SankeyData.Node in
            let node = graph[key]
            return SankeyData.Node(
                key: key,
                name: node?.name ?? key,
                percentageLabel: node?.percentageLabel ?? "",
                layer: node?.type ?? .category,
                isNegative: node?.isNegative ?? false
            )
        }

        var links: [SankeyData.Link] = []
        for (sourceIndex, key) in keys.enumerated() {
            for (to, value) in graph.links(from: key) {
                // Upstream emits dangling links (index -1) after layer
                // trimming; we drop them so the view never sees bad indices.
                guard let targetIndex = indexByKey[to] else { continue }
                links.append(SankeyData.Link(source: sourceIndex, target: targetIndex, value: value))
            }
        }

        return SankeyData(nodes: nodes, links: links, showPercentages: showPercentages)
    }

    // MARK: Date helpers

    private static func monthStart(of date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? date
    }

    private static func endOfMonth(_ monthStartDate: Date) -> Date {
        guard let next = calendar.date(byAdding: .month, value: 1, to: monthStartDate),
              let last = calendar.date(byAdding: .day, value: -1, to: next) else { return monthStartDate }
        return last
    }

    private static func ymdInt(from date: Date) -> Int {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return (comps.year ?? 0) * 10000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
    }

    private static func monthLabel(_ date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    private static func shiftMonth(_ label: String, by months: Int) -> String {
        let parts = label.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let shifted = calendar.date(byAdding: .month, value: months, to: date) else { return label }
        return monthLabel(shifted)
    }

    private static func monthsInRange(start: Date, end: Date) -> Set<Int> {
        var months = Set<Int>()
        var cursor = monthStart(of: start)
        let endMonth = monthStart(of: end)
        while cursor <= endMonth {
            let comps = calendar.dateComponents([.year, .month], from: cursor)
            months.insert((comps.year ?? 0) * 100 + (comps.month ?? 0))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    // MARK: Condition value decoding (private in ConditionsFilter, so local)

    private static func decodeString(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        return try? JSONDecoder().decode(String.self, from: value.raw)
    }

    private static func decodeStringArray(_ value: AnyCodable?) -> [String]? {
        guard let value else { return nil }
        return try? JSONDecoder().decode([String].self, from: value.raw)
    }
}
