import Foundation
import Testing
@testable import Actuali

/// Scenarios ported from upstream sankey-spreadsheet.test.ts, plus
/// engine-level compute coverage.
struct SankeyEngineTests {

    // 2024-01-15 UTC, so the default (nil) time frame is 2024-01.
    private var asOf: Date {
        var c = DateComponents(); c.year = 2024; c.month = 1; c.day = 15
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func tx(
        date: Int, amount: Int, account: String = "a_checking",
        category: String? = nil, payeeId: String? = nil, payeeName: String? = nil
    ) -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: account, date: date, amount: amount,
            payeeId: payeeId, payeeName: payeeName,
            categoryId: category, categoryName: nil,
            notes: nil, cleared: false, reconciled: false,
            transferId: nil, isParent: false, parentId: nil,
            tombstone: false, sortOrder: nil, importedPayee: nil
        )
    }

    private var groups: [CategoryGroup] {
        [
            CategoryGroup(id: "g_income", name: "Income", isIncome: true, hidden: false, sortOrder: 0, categories: [
                Category(id: "c_salary", name: "Salary", groupId: "g_income", isIncome: true, hidden: false, sortOrder: 0)
            ]),
            CategoryGroup(id: "g_food", name: "Food", isIncome: false, hidden: false, sortOrder: 1, categories: [
                Category(id: "c_groceries", name: "Groceries", groupId: "g_food", isIncome: false, hidden: false, sortOrder: 0),
                Category(id: "c_restaurants", name: "Restaurants", groupId: "g_food", isIncome: false, hidden: false, sortOrder: 1),
                Category(id: "c_coffee", name: "Coffee", groupId: "g_food", isIncome: false, hidden: false, sortOrder: 2)
            ])
        ]
    }

    private var context: ConditionsFilter.Context {
        ConditionsFilter.Context(
            offBudgetAccountIds: [],
            accountNames: ["a_checking": "Checking", "a_savings": "Savings"]
        )
    }

    private func meta(
        mode: String? = nil, topN: Int? = nil, sort: String? = nil,
        groupAccounts: Bool? = nil, layerFrom: String? = nil, layerTo: String? = nil
    ) -> SankeyMeta {
        SankeyMeta(
            name: nil, conditions: nil, conditionsOp: nil, timeFrame: nil,
            mode: mode, topNcategories: topN, categorySort: sort,
            showPercentages: nil, groupAccounts: groupAccounts,
            layerFrom: layerFrom, layerTo: layerTo
        )
    }

    private func node(_ data: SankeyData, key: String) -> SankeyData.Node? {
        data.nodes.first { $0.key == key }
    }

    private func linkValue(_ data: SankeyData, from: String, to: String) -> Int? {
        guard let s = data.nodes.firstIndex(where: { $0.key == from }),
              let t = data.nodes.firstIndex(where: { $0.key == to }) else { return nil }
        return data.links.first { $0.source == s && $0.target == t }?.value
    }

    // MARK: - Graph primitives (upstream test ports)

    @Test func getLayerReturnsDepth() {
        var graph = SankeyGraph()
        graph.addNode("root", type: .account, name: "Root")
        graph.addNode("child", type: .category, name: "Child")
        graph.addNode("grandchild", type: .category, name: "Grandchild")
        graph.addValueToLink(from: "root", to: "child", value: 100)
        graph.addValueToLink(from: "child", to: "grandchild", value: 50)

        #expect(SankeyEngine.getLayer(graph, "root") == 0)
        #expect(SankeyEngine.getLayer(graph, "child") == 1)
        #expect(SankeyEngine.getLayer(graph, "grandchild") == 2)
    }

    @Test func getNodeValueSumsOutgoingForRootsIncomingOtherwise() {
        var graph = SankeyGraph()
        graph.addNode("root", type: .account, name: "Root")
        graph.addNode("child", type: .category, name: "Child")
        graph.addValueToLink(from: "root", to: "child", value: 150)
        graph.addValueToLink(from: "root", to: "other-child", value: 200)

        #expect(SankeyEngine.getNodeValue(graph, "root") == 350)
        #expect(SankeyEngine.getNodeValue(graph, "child") == 150)
    }

    @Test func linkValuesAccumulate() {
        var graph = SankeyGraph()
        graph.addNode("source", type: .category, name: "Source")
        graph.addNode("target", type: .category, name: "Target")
        graph.addValueToLink(from: "source", to: "target", value: 100)
        graph.addValueToLink(from: "source", to: "target", value: 50)

        #expect(graph["source"]?.toValues["target"] == 150)
    }

    @Test func sortGraphGlobalSortsByValueDescending() {
        var graph = SankeyGraph()
        graph.addNode("node1", type: .category, name: "Node 1")
        graph.addNode("node2", type: .category, name: "Node 2")
        graph.addNode("node3", type: .category, name: "Node 3")
        graph.addValueToLink(from: "node1", to: "target", value: 100)
        graph.addValueToLink(from: "node2", to: "target", value: 300)
        graph.addValueToLink(from: "node3", to: "target", value: 200)

        SankeyEngine.sortGraph(&graph, categorySort: .global, categoryGroups: [])

        #expect(graph.keys == ["node2", "node3", "node1"])
    }

    @Test func sortGraphPerGroupSortsPayeesAroundIncomeCategories() {
        var graph = SankeyGraph()
        graph.addNode("payee1", type: .incomePayee, name: "Payee 1")
        graph.addNode("payee2", type: .incomePayee, name: "Payee 2")
        graph.addNode("payee3", type: .incomePayee, name: "Payee 3")
        graph.addNode("income1", type: .incomeCategory, name: "Income 1")
        graph.addNode("income2", type: .incomeCategory, name: "Income 2")
        graph.addNode("account1", type: .account, name: "Account 1")
        graph.addValueToLink(from: "payee1", to: "income1", value: 300)
        graph.addValueToLink(from: "payee2", to: "income2", value: 200)
        graph.addValueToLink(from: "payee3", to: "income2", value: 200)
        graph.addValueToLink(from: "income1", to: "account1", value: 300)
        graph.addValueToLink(from: "income2", to: "account1", value: 400)

        SankeyEngine.sortGraph(&graph, categorySort: .perGroup, categoryGroups: [])
        let keys = graph.keys

        let payee1Index = keys.firstIndex(of: "payee1")!
        #expect(keys.firstIndex(of: "payee2")! < payee1Index)
        #expect(keys.firstIndex(of: "payee3")! < payee1Index)
    }

    @Test func sortGraphBudgetOrderFollowsCategoryList() {
        var graph = SankeyGraph()
        graph.addNode("c_groceries", type: .category, name: "Groceries")
        graph.addNode("g_food", type: .categoryGroup, name: "Food")
        graph.addValueToLink(from: "g_food", to: "c_groceries", value: 100)

        SankeyEngine.sortGraph(&graph, categorySort: .budgetOrder, categoryGroups: groups)
        let keys = graph.keys

        #expect(keys.firstIndex(of: "g_food")! < keys.firstIndex(of: "c_groceries")!)
    }

    @Test func addPercentageLabelsNormalizesPerLayer() {
        var graph = SankeyGraph()
        graph.addNode("node1", type: .category, name: "Node 1")
        graph.addNode("node2", type: .category, name: "Node 2")
        graph.addValueToLink(from: "node1", to: "target", value: 250)
        graph.addValueToLink(from: "node2", to: "target", value: 750)

        SankeyEngine.addPercentageLabels(&graph)

        #expect(graph["node1"]?.percentageLabel == "25.0%")
        #expect(graph["node2"]?.percentageLabel == "75.0%")
    }

    @Test func addPercentageLabelsUsesGraphLayerNotDepth() {
        var graph = SankeyGraph()
        graph.addNode("payee", type: .incomePayee, name: "Payee")
        graph.addNode("income-cat", type: .incomeCategory, name: "Income Cat")
        graph.addNode("account-incoming", type: .account, name: "Account A")
        graph.addNode("account-root", type: .account, name: "Account B")
        graph.addNode("group", type: .categoryGroup, name: "Group")
        graph.addValueToLink(from: "payee", to: "income-cat", value: 300)
        graph.addValueToLink(from: "income-cat", to: "account-incoming", value: 300)
        graph.addValueToLink(from: "account-root", to: "group", value: 100)

        SankeyEngine.addPercentageLabels(&graph)

        #expect(graph["account-root"]?.percentageLabel == "25.0%")
        #expect(graph["account-incoming"]?.percentageLabel == "75.0%")
    }

    @Test func filterGraphByLayersKeepsRange() {
        var graph = SankeyGraph()
        graph.addNode("payee1", type: .incomePayee, name: "Payee 1")
        graph.addNode("cat1", type: .incomeCategory, name: "Income Cat 1")
        graph.addNode("acc1", type: .account, name: "Account 1")
        graph.addNode("budget", type: .budget, name: "Budgeted")
        graph.addNode("group1", type: .categoryGroup, name: "Group 1")
        graph.addNode("cat2", type: .category, name: "Category 2")

        SankeyEngine.filterGraphByLayers(&graph, from: .account, to: .categoryGroup)

        #expect(graph["payee1"] == nil)
        #expect(graph["cat1"] == nil)
        #expect(graph["acc1"] != nil)
        #expect(graph["budget"] != nil)
        #expect(graph["group1"] != nil)
        #expect(graph["cat2"] == nil)
    }

    @Test func cleanUpNodesRemovesOrphansAndZeroLinks() {
        var graph = SankeyGraph()
        graph.addNode("used1", type: .category, name: "Used 1")
        graph.addNode("used2", type: .category, name: "Used 2")
        graph.addNode("orphan", type: .category, name: "Orphan")
        graph.addValueToLink(from: "used1", to: "used2", value: 100)

        SankeyEngine.cleanUpNodes(&graph)
        #expect(graph["used1"] != nil)
        #expect(graph["used2"] != nil)
        #expect(graph["orphan"] == nil)

        var zeroed = SankeyGraph()
        zeroed.addNode("node1", type: .category, name: "Node 1")
        zeroed.addNode("node2", type: .category, name: "Node 2")
        zeroed.addValueToLink(from: "node1", to: "node2", value: 0)

        SankeyEngine.cleanUpNodes(&zeroed)
        #expect(zeroed["node1"] == nil)
        #expect(zeroed["node2"] == nil)
    }

    @Test func buildSankeyDataAddsHiddenChildChain() {
        var graph = SankeyGraph()
        graph.addNode("account", type: .account, name: "Account")
        graph.addNode("group-with-child", type: .categoryGroup, name: "Group A")
        graph.addNode("category", type: .category, name: "Category A")
        graph.addValueToLink(from: "account", to: "group-with-child", value: 100)
        graph.addValueToLink(from: "group-with-child", to: "category", value: 100)
        graph.addNode("group-no-child", type: .categoryGroup, name: "Group B")
        graph.addValueToLink(from: "account", to: "group-no-child", value: 50)

        let data = SankeyEngine.buildSankeyData(
            graph, topN: 100, categoryGroups: [], categorySort: .global,
            layerFrom: .account, layerTo: .category
        )

        let keys = data.nodes.map(\.key)
        #expect(keys.contains("group-no-child_category__HIDDEN"))
        #expect(!keys.contains("group-no-child_category_group__HIDDEN"))
    }

    @Test func convertToSankeyDataBasics() {
        var graph = SankeyGraph()
        graph.addNode("node1", type: .category, name: "Node 1")
        graph.addNode("node2", type: .category, name: "Node 2")
        graph.addValueToLink(from: "node1", to: "node2", value: 100)
        graph.nodes["node1"]?.percentageLabel = "100.0%"

        let data = SankeyEngine.convertToSankeyData(graph)

        #expect(data.nodes.count == 2)
        #expect(data.links == [SankeyData.Link(source: 0, target: 1, value: 100)])
        #expect(data.nodes[0].percentageLabel == "100.0%")
        #expect(data.nodes[1].percentageLabel == "")
    }

    @Test func createBudgetGraphBuildsEnvelopeNodes() {
        let entries = [
            SankeyCategoryEntry(categoryGroup: "Income", categoryGroupId: "g_income",
                                category: "Salary", categoryId: "c_salary",
                                value: 5000, isIncome: true, isNegative: false),
            SankeyCategoryEntry(categoryGroup: "Food", categoryGroupId: "g_food",
                                category: "Groceries", categoryId: "c_groceries",
                                value: 500, isIncome: false, isNegative: false)
        ]
        let input = SankeyBudgetInput(entries: [], toBudgetCents: 1000,
                                      fromPreviousMonthCents: 200,
                                      lastMonthOverspentCents: 0, forNextMonthCents: 300)

        let graph = SankeyEngine.createBudgetGraph(entries, budget: input, startMonth: "2024-01", endMonth: "2024-01")

        #expect(graph["c_salary"] != nil)
        #expect(graph["c_groceries"] != nil)
        #expect(graph["budgeted"] != nil)
        #expect(graph["available_income"] != nil)
        #expect(graph["to_budget"] != nil)
        #expect(graph["from_previous_month"]?.name == "From 2023-12")
        #expect(graph["for_next_month"]?.name == "For 2024-02")
    }

    @Test func createBudgetGraphMarksOverbudgeted() {
        let input = SankeyBudgetInput(entries: [], toBudgetCents: -500)
        let graph = SankeyEngine.createBudgetGraph([], budget: input, startMonth: "2024-01", endMonth: "2024-01")

        #expect(graph["to_budget"]?.isNegative == true)
        #expect(graph["to_budget"]?.name == "Overbudgeted")
        #expect(graph["to_budget"]?.toValues["budgeted"] == 500)
    }

    @Test func createTransactionsGraphBuildsNodes() {
        let entries = [
            SankeyCategoryEntry(categoryGroup: "Food", categoryGroupId: "g_food",
                                category: "Groceries", categoryId: "c_groceries",
                                value: 100, isIncome: false, isNegative: true,
                                accountName: "Checking", accountId: "a_checking"),
            SankeyCategoryEntry(categoryGroup: "Income", categoryGroupId: "g_income",
                                category: "Salary", categoryId: "c_salary",
                                value: 5000, isIncome: true, isNegative: false,
                                accountName: "Checking", accountId: "a_checking",
                                payeeName: "Employer", payeeId: "p_employer")
        ]

        let graph = SankeyEngine.createTransactionsGraph(entries)

        #expect(graph["a_checking"] != nil)
        #expect(graph["c_groceries"] != nil)
        #expect(graph["c_salary"] != nil)
        #expect(graph["p_employer"] != nil)
    }

    @Test func filterCategoryGroupsByConditions() {
        func cond(_ field: String, _ op: String, _ value: String) -> WidgetRuleCondition {
            WidgetRuleCondition(op: op, field: field,
                                value: AnyCodable(rawJSON: Data("\"\(value)\"".utf8)),
                                options: nil, customName: nil)
        }

        let isCat = SankeyEngine.filterCategoryGroups(groups, conditions: [cond("category", "is", "c_groceries")], conditionsOp: "and")
        #expect(isCat.count == 1)
        #expect(isCat[0].categories.map(\.id) == ["c_groceries"])

        let containsCat = SankeyEngine.filterCategoryGroups(groups, conditions: [cond("category", "contains", "groceries")], conditionsOp: "and")
        #expect(containsCat[0].categories.map(\.name) == ["Groceries"])

        let isGroup = SankeyEngine.filterCategoryGroups(groups, conditions: [cond("category_group", "is", "g_food")], conditionsOp: "and")
        #expect(isGroup.map(\.id) == ["g_food"])

        let none = SankeyEngine.filterCategoryGroups(groups, conditions: [cond("category", "is", "nonexistent")], conditionsOp: "and")
        #expect(none.isEmpty)
    }

    // MARK: - Engine compute (spent)

    @Test func spentModeBuildsPayeeIncomeAccountAndCategoryFlows() {
        let transactions = [
            tx(date: 20240105, amount: 500000, category: "c_salary", payeeId: "p_employer", payeeName: "Employer"),
            tx(date: 20240110, amount: -10000, category: "c_groceries"),
            tx(date: 20240112, amount: -2000, category: "c_groceries")
        ]

        let data = SankeyEngine.compute(
            meta: meta(), transactions: transactions, categoryGroups: groups,
            today: asOf, context: context
        )

        #expect(node(data, key: "p_employer")?.name == "Employer")
        #expect(node(data, key: "c_salary")?.name == "Salary")
        #expect(node(data, key: "a_checking")?.name == "Checking")
        #expect(node(data, key: "g_food")?.name == "Food")
        #expect(node(data, key: "c_groceries")?.name == "Groceries")

        #expect(linkValue(data, from: "p_employer", to: "c_salary") == 500000)
        #expect(linkValue(data, from: "c_salary", to: "a_checking") == 500000)
        #expect(linkValue(data, from: "a_checking", to: "g_food") == 12000)
        #expect(linkValue(data, from: "g_food", to: "c_groceries") == 12000)
    }

    @Test func topNBucketsSmallestCategoriesIntoOther() {
        let transactions = [
            tx(date: 20240102, amount: -30000, category: "c_groceries"),
            tx(date: 20240103, amount: -20000, category: "c_restaurants"),
            tx(date: 20240104, amount: -10000, category: "c_coffee")
        ]

        let data = SankeyEngine.compute(
            meta: meta(topN: 2), transactions: transactions, categoryGroups: groups,
            today: asOf, context: context
        )

        // per-group sort buckets into the category group's Other node
        let other = node(data, key: "g_food__OTHER_BUCKET")
        #expect(other?.name == "Other")
        #expect(linkValue(data, from: "g_food", to: "g_food__OTHER_BUCKET") == 30000)
        #expect(linkValue(data, from: "g_food", to: "c_groceries") == 30000)
        #expect(node(data, key: "c_restaurants") == nil)
        #expect(node(data, key: "c_coffee") == nil)
    }

    @Test func groupAccountsCollapsesAccountsIntoIncomeNode() {
        let transactions = [
            tx(date: 20240105, amount: 300000, account: "a_checking", category: "c_salary", payeeId: "p_employer", payeeName: "Employer"),
            tx(date: 20240106, amount: 200000, account: "a_savings", category: "c_salary", payeeId: "p_employer", payeeName: "Employer")
        ]

        let grouped = SankeyEngine.compute(
            meta: meta(groupAccounts: true), transactions: transactions, categoryGroups: groups,
            today: asOf, context: context
        )
        #expect(node(grouped, key: "all_income")?.name == "Income")
        #expect(node(grouped, key: "a_checking") == nil)
        #expect(linkValue(grouped, from: "c_salary", to: "all_income") == 500000)

        let ungrouped = SankeyEngine.compute(
            meta: meta(), transactions: transactions, categoryGroups: groups,
            today: asOf, context: context
        )
        #expect(node(ungrouped, key: "a_checking")?.name == "Checking")
        #expect(node(ungrouped, key: "a_savings")?.name == "Savings")
        #expect(node(ungrouped, key: "all_income") == nil)
    }

    @Test func layerTrimmingDropsOutOfRangeLayers() {
        let transactions = [
            tx(date: 20240105, amount: 500000, category: "c_salary", payeeId: "p_employer", payeeName: "Employer"),
            tx(date: 20240110, amount: -10000, category: "c_groceries")
        ]

        let data = SankeyEngine.compute(
            meta: meta(layerFrom: "account", layerTo: "category_group"),
            transactions: transactions, categoryGroups: groups,
            today: asOf, context: context
        )

        #expect(node(data, key: "p_employer") == nil)
        #expect(node(data, key: "c_salary") == nil)
        #expect(node(data, key: "a_checking") != nil)
        #expect(node(data, key: "g_food") != nil)
        #expect(node(data, key: "c_groceries") == nil)
    }

    @Test func globalSortOrdersCategoriesByValue() {
        let transactions = [
            tx(date: 20240102, amount: -10000, category: "c_groceries"),
            tx(date: 20240103, amount: -30000, category: "c_restaurants"),
            tx(date: 20240104, amount: -20000, category: "c_coffee")
        ]

        let data = SankeyEngine.compute(
            meta: meta(sort: "global"), transactions: transactions, categoryGroups: groups,
            today: asOf, context: context
        )

        let categoryKeys = data.nodes.filter { $0.layer == .category }.map(\.key)
        #expect(categoryKeys == ["c_restaurants", "c_coffee", "c_groceries"])
    }

    // MARK: - Engine compute (budgeted)

    @Test func budgetedModeBuildsEnvelopeGraph() {
        let transactions = [
            tx(date: 20240105, amount: 500000, category: "c_salary", payeeId: "p_employer", payeeName: "Employer")
        ]
        let budget = SankeyBudgetInput(
            entries: [SankeyBudgetInput.Entry(month: 202401, categoryId: "c_groceries", amountCents: 50000)],
            toBudgetCents: 100000, fromPreviousMonthCents: 20000,
            lastMonthOverspentCents: 0, forNextMonthCents: 30000
        )

        let data = SankeyEngine.compute(
            meta: meta(mode: "budgeted"), transactions: transactions, categoryGroups: groups,
            budget: budget, today: asOf, context: context
        )

        #expect(node(data, key: "budgeted")?.name == "Budgeted")
        #expect(node(data, key: "available_income")?.name == "Available funds")
        #expect(node(data, key: "to_budget")?.name == "To budget")
        #expect(node(data, key: "from_previous_month")?.name == "From 2023-12")

        #expect(linkValue(data, from: "c_salary", to: "available_income") == 500000)
        #expect(linkValue(data, from: "available_income", to: "budgeted") == 50000)
        #expect(linkValue(data, from: "budgeted", to: "g_food") == 50000)
        #expect(linkValue(data, from: "g_food", to: "c_groceries") == 50000)
        #expect(linkValue(data, from: "available_income", to: "to_budget") == 100000)
        #expect(linkValue(data, from: "from_previous_month", to: "available_income") == 20000)

        // Zero-value overspent flow is cleaned up entirely.
        #expect(node(data, key: "last_month_overspent") == nil)
        // Payee layer never appears in budgeted mode (default layer range).
        #expect(node(data, key: "p_employer") == nil)
        // "To budget" sits in the group layer with no child, so it gets a
        // hidden child chain to pin its column.
        #expect(data.nodes.map(\.key).contains("to_budget_category__HIDDEN"))
    }
}
