import Foundation

/// Detects recurring transactions and proposes schedules for them.
/// Port of loot-core `find-schedules.ts`.
enum ScheduleDiscovery {

    /// A transaction eligible to take part in a pattern.
    struct Candidate: Equatable {
        let id: String
        let date: DayDate
        let amount: Int
        let payeeId: String
        let accountId: String
    }

    /// A pattern that matched, before payee-level deduplication.
    struct Match {
        let rank: Double
        let amount: Int
        let accountId: String
        let payeeId: String
        let config: RecurConfig
        /// Every occurrence landed exactly on its date.
        let exactDate: Bool
        /// Every matched transaction carried exactly the same amount.
        let exactAmount: Bool
    }

    /// A proposal shown to the user.
    struct Proposal: Identifiable {
        let id = UUID()
        let accountId: String
        let payeeId: String
        let amount: Int
        let config: RecurConfig
        let exactDate: Bool
        let exactAmount: Bool

        /// The form the create path takes. Date and amount operators reflect
        /// how exactly the history matched, exactly as upstream does.
        var formFields: ScheduleFormFields {
            ScheduleFormFields(
                name: nil,
                payeeId: payeeId,
                accountId: accountId,
                amount: .fixed(amount),
                amountOp: exactAmount ? .isExactly : .isApprox,
                date: .recurring(config),
                postsTransaction: false,
                customUpcomingLength: nil)
        }
    }

    /// How far an amount may drift and still count as the same payment —
    /// upstream's `getApproxNumberThreshold`, 7.5%.
    static func approxThreshold(_ amount: Int) -> Int {
        Int((Double(abs(amount)) * 0.075).rounded())
    }

    /// Closeness of two dates: an exact hit is 1, one day off is 0.5, and so
    /// on. Summed across occurrences, this picks the start date that fits the
    /// history best.
    static func rank(_ a: DayDate, _ b: DayDate) -> Double {
        1.0 / (Double(abs(a.days(until: b))) + 1.0)
    }

    // MARK: - Entry point

    /// Scan every open account and return one proposal per payee.
    static func discover(
        accounts: [Account],
        loadCandidates: (String, Int) throws -> [Candidate],
        latestDate: (String) throws -> DayDate?
    ) rethrows -> [Proposal] {
        var matches: [Match] = []

        for account in accounts where !account.closed {
            guard let latest = try latestDate(account.id) else { continue }
            // Every sweep starts at most ~8 months back; one load covers them
            // all, with a month of slack for the ±2-day windows.
            let earliest = latest.adding(months: -9)
            let candidates = try loadCandidates(account.id, earliest.yyyymmdd)
            guard !candidates.isEmpty else { continue }

            let index = CandidateIndex(candidates)
            for sweep in sweeps(from: latest) {
                matches += run(sweep: sweep, index: index, accountId: account.id)
            }
        }

        // One proposal per payee: the highest-ranked pattern wins.
        return Dictionary(grouping: matches, by: \.payeeId)
            .compactMap { _, group in group.max { $0.rank < $1.rank } }
            .map { match in
                Proposal(
                    accountId: match.accountId,
                    payeeId: match.payeeId,
                    amount: match.amount,
                    config: match.config,
                    exactDate: match.exactDate,
                    exactAmount: match.exactAmount)
            }
            .sorted { $0.payeeId < $1.payeeId }
    }

    // MARK: - Sweeps

    /// A range of candidate start dates plus the config each one produces.
    struct Sweep {
        let start: DayDate
        let dayCount: Int
        /// Returns nil to skip a start date, mirroring upstream's `false`.
        let makeConfig: (DayDate) -> RecurConfig?
    }

    static func sweeps(from latest: DayDate) -> [Sweep] {
        let weekdayCode = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][latest.weekday - 1]

        return [
            Sweep(start: latest.adding(days: -28), dayCount: 14) { start in
                RecurConfig(frequency: .weekly, start: start)
            },
            // Six weeks covers three occurrences; upstream scans one more.
            Sweep(start: latest.adding(days: -49), dayCount: 14) { start in
                RecurConfig(frequency: .weekly, interval: 2, start: start)
            },
            Sweep(start: latest.adding(months: -4), dayCount: 62) { start in
                // 28 is the highest day every month is guaranteed to have;
                // past that a monthly schedule would skip short months. The
                // last-day sweep below covers month ends instead.
                guard start.day <= 28 else { return nil }
                return RecurConfig(frequency: .monthly, start: start)
            },
            Sweep(start: latest.adding(months: -3), dayCount: 1) { start in
                RecurConfig(frequency: .monthly, start: start,
                            patterns: [.init(type: "day", value: -1)])
            },
            Sweep(start: latest.adding(months: -4), dayCount: 1) { start in
                RecurConfig(frequency: .monthly, start: start,
                            patterns: [.init(type: "day", value: -1)])
            },
            Sweep(start: latest.adding(days: -56), dayCount: 14) { start in
                RecurConfig(frequency: .monthly, start: start,
                            patterns: [.init(type: weekdayCode, value: 1),
                                       .init(type: weekdayCode, value: 3)])
            },
            Sweep(start: latest.adding(months: -8), dayCount: 14) { start in
                RecurConfig(frequency: .monthly, start: start,
                            patterns: [.init(type: weekdayCode, value: 2),
                                       .init(type: weekdayCode, value: 4)])
            },
        ]
    }

    private static func run(sweep: Sweep, index: CandidateIndex, accountId: String) -> [Match] {
        var matches: [Match] = []
        for offset in 0..<sweep.dayCount {
            let start = sweep.start.adding(days: offset)
            guard let config = sweep.makeConfig(start) else { continue }

            let occurrences = ScheduleRecurrence.upcomingDates(
                for: config, count: 3, from: start)
            guard occurrences.count == 3 else { continue }

            let window = occurrences.map { date in
                (date: date, transactions: index.near(date, days: 2))
            }
            matches += match(occurrences: window, config: config, accountId: accountId)
        }
        return matches
    }

    // MARK: - Matching

    /// Port of upstream `matchSchedules`.
    ///
    /// Anchored on the LAST occurrence (upstream reverses the array first), so
    /// a pattern is judged by the most recent payment and traced backwards.
    static func match(
        occurrences: [(date: DayDate, transactions: [Candidate])],
        config: RecurConfig,
        accountId: String
    ) -> [Match] {
        let reversed = Array(occurrences.reversed())
        guard let anchor = reversed.first else { return [] }
        let rest = reversed.dropFirst()

        var matches: [Match] = []
        for transaction in anchor.transactions {
            let threshold = approxThreshold(transaction.amount)

            // Every other occurrence must contain the same payee at a
            // comparable amount, or this isn't a pattern.
            var found: [(candidate: Candidate, rank: Double)] = []
            var complete = true
            for occurrence in rest {
                let hit = occurrence.transactions.first { candidate in
                    candidate.payeeId == transaction.payeeId
                        && candidate.amount >= transaction.amount - threshold
                        && candidate.amount <= transaction.amount + threshold
                }
                guard let hit else { complete = false; break }
                found.append((hit, rank(occurrence.date, hit.date)))
            }
            guard complete else { continue }

            let total = found.reduce(rank(anchor.date, transaction.date)) { $0 + $1.rank }
            let exactAmount = found.allSatisfy { $0.candidate.amount == transaction.amount }

            matches.append(Match(
                rank: total,
                amount: transaction.amount,
                accountId: accountId,
                payeeId: transaction.payeeId,
                config: config,
                // Every occurrence scoring 1 sums to the occurrence count.
                exactDate: total == Double(occurrences.count),
                exactAmount: exactAmount))
        }
        return matches
    }

    /// Date-bucketed candidates, so the ±2-day window is a lookup rather than
    /// a query. This is the in-memory replacement for upstream's
    /// per-occurrence database call.
    struct CandidateIndex {
        private var byDate: [Int: [Candidate]] = [:]

        init(_ candidates: [Candidate]) {
            for candidate in candidates {
                byDate[candidate.date.yyyymmdd, default: []].append(candidate)
            }
        }

        func near(_ date: DayDate, days: Int) -> [Candidate] {
            (-days...days).flatMap { byDate[date.adding(days: $0).yyyymmdd] ?? [] }
        }
    }
}
