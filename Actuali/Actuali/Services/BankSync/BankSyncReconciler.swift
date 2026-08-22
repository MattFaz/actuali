import Foundation

/// One downloaded transaction, normalized into the budget's own units and
/// ready to be matched against what's already in the account.
struct BankSyncCandidate: Sendable, Equatable {
    /// The provider's transaction id — stored as `financial_id` and the
    /// highest-fidelity way to recognise a transaction we already imported.
    var importedId: String
    var date: Int // YYYYMMDD
    var amount: Int // cents, negative = outflow
    var payeeName: String
    /// The existing payee `payeeName` resolves to, or nil when the budget has
    /// no payee by that name yet. Resolved before matching because the payee
    /// pass compares ids, not names.
    var payeeId: String?
    var notes: String?
    /// Booked at the bank. Pending transactions import uncleared and clear on
    /// a later sync, once the bank posts them.
    var cleared: Bool
}

/// An existing transaction in the fuzzy-match window, projected down to just
/// the columns matching reads.
struct BankSyncExistingTransaction: Sendable, Equatable {
    var id: String
    var date: Int // YYYYMMDD
    var amount: Int // cents
    var payeeId: String?
    var importedId: String?
    var importedPayee: String?
    var notes: String?
    var cleared: Bool
    var reconciled: Bool
}

/// The columns a matched transaction takes from the downloaded one.
struct BankSyncUpdate: Sendable, Equatable {
    var existingId: String
    var importedId: String
    var payeeId: String?
    var importedPayee: String?
    var notes: String?
    var cleared: Bool
}

struct BankSyncPlan: Sendable, Equatable {
    var inserts: [BankSyncCandidate] = []
    var updates: [BankSyncUpdate] = []
    /// Downloaded transactions that matched something already correct — the
    /// ordinary case for every sync after the first.
    var unchanged: Int = 0

    var isEmpty: Bool { inserts.isEmpty && updates.isEmpty }
}

/// Decides which downloaded transactions are new, which ones are transactions
/// the budget already has, and what the latter should take from them.
///
/// Port of upstream loot-core `matchTransactions` / `reconcileTransactions`
/// (`server/accounts/sync.ts`) for the bank-sync case, so a transaction
/// entered by hand before it reached the bank feed is updated rather than
/// duplicated. Three passes, highest fidelity first: the provider's own
/// transaction id, then same-payee, then anything left in the window.
///
/// Pure and synchronous — the caller does the payee lookups and the writing.
enum BankSyncReconciler {
    /// How far either side of a downloaded transaction's date to look for the
    /// transaction it might already be, matching upstream's window.
    static let fuzzyMatchDayRadius = 7

    static func plan(
        candidates: [BankSyncCandidate],
        existing: [BankSyncExistingTransaction]
    ) -> BankSyncPlan {
        var matchedIds = Set<String>()
        var plan = BankSyncPlan()

        // Pass 1: the provider's transaction id. Anything that misses gets a
        // window of same-amount transactions to try the later passes against,
        // nearest date first.
        //
        // Unlike a file import, the window deliberately keeps rows that
        // already carry a *different* imported id (upstream's
        // `strictIdChecking: false` for bank-sync accounts): providers hand
        // out a new id for the same transaction often enough — a pending
        // charge that posts, most commonly — that excluding them would
        // duplicate it.
        var pending: [(candidate: BankSyncCandidate, match: BankSyncExistingTransaction?, window: [BankSyncExistingTransaction])] = []
        for candidate in candidates {
            if let match = existing.first(where: {
                $0.importedId == candidate.importedId && !matchedIds.contains($0.id)
            }) {
                matchedIds.insert(match.id)
                pending.append((candidate, match, []))
                continue
            }
            let window = existing
                .filter {
                    $0.amount == candidate.amount
                        && abs(dayNumber($0.date) - dayNumber(candidate.date)) <= fuzzyMatchDayRadius
                }
                .sorted {
                    abs(dayNumber($0.date) - dayNumber(candidate.date))
                        < abs(dayNumber($1.date) - dayNumber(candidate.date))
                }
            pending.append((candidate, nil, window))
        }

        // Pass 2: same payee. Runs across every candidate before pass 3 so a
        // confident match always wins the row a vaguer one would have taken.
        for index in pending.indices {
            guard pending[index].match == nil, let payeeId = pending[index].candidate.payeeId else { continue }
            guard let match = pending[index].window.first(where: {
                !matchedIds.contains($0.id) && $0.payeeId == payeeId
            }) else { continue }
            matchedIds.insert(match.id)
            pending[index].match = match
        }

        // Pass 3: whatever is left in the window — same account, same amount,
        // within a week.
        for index in pending.indices {
            guard pending[index].match == nil else { continue }
            guard let match = pending[index].window.first(where: { !matchedIds.contains($0.id) }) else { continue }
            matchedIds.insert(match.id)
            pending[index].match = match
        }

        for entry in pending {
            guard let match = entry.match else {
                plan.inserts.append(entry.candidate)
                continue
            }
            // Reconciled transactions are locked; upstream leaves them alone.
            guard !match.reconciled else {
                plan.unchanged += 1
                continue
            }
            let update = self.update(for: entry.candidate, matching: match)
            if changed(update, from: match) {
                plan.updates.append(update)
            } else {
                plan.unchanged += 1
            }
        }

        return plan
    }

    /// What a matched transaction ends up with. Anything the person already
    /// filled in wins — the download only fills blanks — except the two fields
    /// that are the bank's to state: its transaction id and whether it posted.
    private static func update(
        for candidate: BankSyncCandidate,
        matching existing: BankSyncExistingTransaction
    ) -> BankSyncUpdate {
        BankSyncUpdate(
            existingId: existing.id,
            importedId: candidate.importedId,
            payeeId: existing.payeeId ?? candidate.payeeId,
            importedPayee: candidate.payeeName,
            notes: existing.notes ?? candidate.notes,
            cleared: existing.cleared || candidate.cleared
        )
    }

    private static func changed(_ update: BankSyncUpdate, from existing: BankSyncExistingTransaction) -> Bool {
        update.importedId != existing.importedId
            || update.payeeId != existing.payeeId
            || update.importedPayee != existing.importedPayee
            || update.notes != existing.notes
            || update.cleared != existing.cleared
    }

    /// Days since an arbitrary epoch for a `YYYYMMDD` date, via the standard
    /// Julian day number formula. Calendar-free so the match window is the
    /// same width in every time zone.
    static func dayNumber(_ yyyymmdd: Int) -> Int {
        let year = yyyymmdd / 10000
        let month = (yyyymmdd % 10000) / 100
        let day = yyyymmdd % 100
        let priorMonths = (14 - month) / 12
        let years = year + 4800 - priorMonths
        let months = month + 12 * priorMonths - 3
        return day + (153 * months + 2) / 5 + 365 * years
            + years / 4 - years / 100 + years / 400 - 32045
    }

    /// A `YYYYMMDD` date moved by whole days, month and year rollovers
    /// included. The inverse of `dayNumber`, so the match window's edges are
    /// computed the same way its width is.
    static func day(_ yyyymmdd: Int, offsetBy days: Int) -> Int {
        let shifted = dayNumber(yyyymmdd) + days + 32044
        let centuries = (4 * shifted + 3) / 146097
        let withinCentury = shifted - 146097 * centuries / 4
        let years = (4 * withinCentury + 3) / 1461
        let withinYear = withinCentury - 1461 * years / 4
        let months = (5 * withinYear + 2) / 153
        let day = withinYear - (153 * months + 2) / 5 + 1
        let month = months + 3 - 12 * (months / 10)
        let year = 100 * centuries + years - 4800 + months / 10
        return year * 10000 + month * 100 + day
    }
}

// MARK: - Normalization

extension BankSyncCandidate {
    /// Turn a SimpleFIN transaction into a candidate, or nil when it carries
    /// no readable amount (nothing sensible to import).
    ///
    /// Mirrors upstream's `normalizeBankSyncTransactions` for the fields
    /// SimpleFIN provides: the bridge's `payee` is the payee, its
    /// `description` the notes, and its `id` the dedup key.
    /// `payeeId` is left nil — the caller resolves it.
    init?(simpleFIN transaction: SimpleFINTransaction) {
        guard let amount = transaction.amountCents else { return nil }
        self.init(
            importedId: transaction.id,
            date: SimpleFINAmount.day(fromTimestamp: transaction.effectiveTimestamp),
            amount: amount,
            payeeName: Self.payeeName(for: transaction),
            payeeId: nil,
            notes: Self.notes(for: transaction),
            cleared: transaction.isBooked
        )
    }

    /// The bridge's `payee` when it has one. Not every bridge fills it in, so
    /// fall back to the description rather than importing a nameless payee.
    private static func payeeName(for transaction: SimpleFINTransaction) -> String {
        for candidate in [transaction.payee, transaction.description, transaction.memo] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return "Unknown"
    }

    private static func notes(for transaction: SimpleFINTransaction) -> String? {
        let trimmed = transaction.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        // Escape `#` the way upstream does, so a bank's own "#" in a
        // description doesn't silently become a tag (see TagFilter, where a
        // doubled `#` never matches).
        return trimmed.replacingOccurrences(of: "#", with: "##")
    }
}
