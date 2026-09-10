/// Pure port of Actual's end-of-month cleanup ordering. Budget writes update
/// the in-memory sheet as they go, matching the web spreadsheet recalculation.
enum CleanupEngine {
    struct Category: Equatable, Sendable {
        let id: String
        let name: String
        let isIncome: Bool
        let cleanup: [CleanupTemplate]

        init(id: String, name: String, isIncome: Bool = false, cleanup: [CleanupTemplate]) {
            self.id = id
            self.name = name
            self.isIncome = isIncome
            self.cleanup = cleanup
        }
    }

    enum Warning: Equatable, Sendable {
        case noAvailableFunds(category: String)
        case noMatchingSinks(group: String)
        case noGlobalFunds
    }

    enum Notification: Equatable, Sendable {
        case applied(sourceCount: Int, sinkCount: Int)
        case upToDate
        case warning([Warning])
    }

    struct Result: Equatable, Sendable {
        let budgets: [GoalTemplateEngine.BudgetWrite]
        let goals: [GoalTemplateEngine.GoalWrite]
        let notification: Notification
    }

    private struct SheetState {
        let month: String
        let sheet: GoalTemplateSheet
        var available: Int
        var currentBudgets: [String: Int] = [:]
        var currentLeftovers: [String: Int] = [:]
        var writes: [GoalTemplateEngine.BudgetWrite] = []
        var writeIndices: [String: Int] = [:]

        init(month: String, sheet: GoalTemplateSheet) {
            self.month = month
            self.sheet = sheet
            available = sheet.availableStart
        }

        func budget(_ category: String) -> Int {
            currentBudgets[category] ?? sheet.budgeted(month: month, category: category)
        }

        func leftover(_ category: String) -> Int {
            currentLeftovers[category] ?? sheet.leftover(month: month, category: category)
        }

        mutating func setBudget(_ amount: Int, for category: String) {
            let previous = budget(category)
            let delta = amount - previous
            currentBudgets[category] = amount
            currentLeftovers[category] = leftover(category) + delta
            available -= delta
            guard delta != 0 else { return }
            let write = GoalTemplateEngine.BudgetWrite(category: category, amount: amount)
            if let index = writeIndices[category] {
                writes[index] = write
            } else {
                writeIndices[category] = writes.count
                writes.append(write)
            }
        }
    }

    static func run(
        month: String,
        categories: [Category],
        groupNames: [String: String],
        sheet: GoalTemplateSheet
    ) -> Result {
        var state = SheetState(month: month, sheet: sheet)
        var goals: [GoalTemplateEngine.GoalWrite] = []
        var warnings: [Warning] = []

        let groupSources = categories.flatMap { category in
            category.cleanup.compactMap { row in
                row.role == .source ? row.groupId.map { (category, $0) } : nil
            }
        }
        let groupSinks = categories.flatMap { category in
            category.cleanup.compactMap { row in
                row.role == .sink ? row.groupId.map { (category, $0, validWeight(row.weight)) } : nil
            }
        }
        let groupOverspending = categories.flatMap { category in
            category.cleanup.compactMap { row in
                row.role == .overspend ? row.groupId.map { (category, $0) } : nil
            }
        }

        var processedGroups: Set<String> = []
        for (_, groupId) in groupSources where processedGroups.insert(groupId).inserted {
            let sources = groupSources.filter { $0.1 == groupId }
            let sinks = groupSinks.filter { $0.1 == groupId }
            let overspending = groupOverspending.filter { $0.1 == groupId }
            guard !sinks.isEmpty || !overspending.isEmpty else {
                warnings.append(.noMatchingSinks(group: groupNames[groupId] ?? groupId))
                continue
            }

            var pool = 0
            for (category, _) in sources {
                let balance = state.leftover(category.id)
                guard balance >= 0 else {
                    warnings.append(.noAvailableFunds(category: category.name))
                    continue
                }
                state.setBudget(state.budget(category.id) - balance, for: category.id)
                pool += balance
            }

            for (category, _) in overspending where pool > 0 {
                let balance = state.leftover(category.id)
                guard balance < 0, !sheet.carryover(month: month, category: category.id) else {
                    continue
                }
                let amount = min(-balance, pool)
                state.setBudget(state.budget(category.id) + amount, for: category.id)
                pool -= amount
            }

            let totalWeight = sinks.reduce(0.0) { $0 + $1.2 }
            var remainingPool = pool
            for (index, sink) in sinks.enumerated() where remainingPool > 0 {
                let (category, _, weight) = sink
                let share = index == sinks.count - 1
                    ? remainingPool
                    : min(
                        BudgetMonthMath.jsRound(weight / totalWeight * Double(pool)),
                        remainingPool)
                state.setBudget(state.budget(category.id) + share, for: category.id)
                remainingPool -= share
            }
        }

        var globalSinks: [(Category, Double)] = []
        var sourceCount = 0
        for category in categories {
            if category.cleanup.contains(where: { $0.role == .source && $0.groupId == nil }) {
                let balance = state.leftover(category.id)
                if balance >= 0 {
                    let amount = state.budget(category.id) - balance
                    state.setBudget(amount, for: category.id)
                    goals.append(.init(category: category.id, goal: amount, longGoal: false))
                    sourceCount += 1
                } else {
                    warnings.append(.noAvailableFunds(category: category.name))
                }
            }
            if let sink = category.cleanup.first(where: { $0.role == .sink && $0.groupId == nil }) {
                globalSinks.append((category, validWeight(sink.weight)))
            }
        }

        for category in categories {
            guard state.available > 0 else { break }
            let balance = state.leftover(category.id)
            guard balance < 0, !category.isIncome,
                  !sheet.carryover(month: month, category: category.id) else { continue }
            state.setBudget(state.budget(category.id) + min(-balance, state.available), for: category.id)
        }

        let budgetAvailable = state.available
        if budgetAvailable < 0 { warnings.append(.noGlobalFunds) }

        let totalWeight = globalSinks.reduce(0.0) { $0 + $1.1 }
        var remainingBudget = max(budgetAvailable, 0)
        for (index, sink) in globalSinks.enumerated() where remainingBudget > 0 {
            let share = index == globalSinks.count - 1
                ? remainingBudget
                : min(
                    BudgetMonthMath.jsRound(
                        sink.1 / totalWeight * Double(budgetAvailable)),
                    remainingBudget)
            state.setBudget(state.budget(sink.0.id) + share, for: sink.0.id)
            remainingBudget -= share
        }

        let notification: Notification
        if !warnings.isEmpty {
            notification = .warning(warnings)
        } else if state.writes.isEmpty && goals.isEmpty {
            notification = .upToDate
        } else {
            notification = .applied(sourceCount: sourceCount, sinkCount: globalSinks.count)
        }
        return Result(budgets: state.writes, goals: goals, notification: notification)
    }

    private static func validWeight(_ weight: Double) -> Double {
        weight.isFinite && weight > 0 ? weight : 1
    }
}
