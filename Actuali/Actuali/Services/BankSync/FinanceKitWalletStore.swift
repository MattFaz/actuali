import FinanceKit
import Foundation

/// The real FinanceKit-backed `AppleWalletReading`. Deliberately thin — every
/// mapping decision lives in the framework-free types so it can be tested;
/// this file only speaks to `FinanceStore`.
///
/// Ongoing access needs Apple's managed FinanceKit entitlement
/// (`com.apple.developer.financekit` in Actuali.entitlements) — unlike the
/// Tier-1 transaction picker, which works in any build.
struct FinanceKitWalletStore: AppleWalletReading {

    func availability() async -> AppleWalletAvailability {
        #if targetEnvironment(simulator)
        // FinanceStore.shared traps in unsigned simulator builds before it can throw.
        return .unsupported
        #else
        guard FinanceStore.isDataAvailable(.financialData) else { return .unsupported }
        // authorizationStatus throws in builds without the FinanceKit
        // entitlement; treated as not-determined so the setup screen's
        // connect button is what surfaces the real error.
        switch try? await FinanceStore.shared.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        default: return .notDetermined
        }
        #endif
    }

    func requestAccess() async throws -> Bool {
        try await FinanceStore.shared.requestAuthorization() == .authorized
    }

    func accounts() async throws -> [AppleWalletAccount] {
        let accounts = try await FinanceStore.shared.accounts(query: AccountQuery())
        var result: [AppleWalletAccount] = []
        for account in accounts {
            let accountId = account.id
            let available = try await FinanceStore.shared.accountBalances(query: AccountBalanceQuery(
                sortDescriptors: [SortDescriptor(\AccountBalance.available?.asOfDate, order: .reverse)],
                predicate: #Predicate<AccountBalance> {
                    $0.accountID == accountId && $0.available != nil
                },
                limit: 1
            ))
            let booked = try await FinanceStore.shared.accountBalances(query: AccountBalanceQuery(
                sortDescriptors: [SortDescriptor(\AccountBalance.booked?.asOfDate, order: .reverse)],
                predicate: #Predicate<AccountBalance> {
                    $0.accountID == accountId && $0.booked != nil
                },
                limit: 1
            ))
            let balance = Self.latestBalance((available + booked).compactMap {
                Self.balance(from: $0, for: account)
            })
            result.append(AppleWalletAccount(
                id: account.id.uuidString,
                name: account.displayName,
                institutionName: account.institutionName,
                balanceCents: balance?.cents,
                balanceIncludesPending: balance?.includesPending ?? false
            ))
        }
        return result
    }

    func transactions(accountId: String, sinceDay: Int) async throws -> [AppleWalletTransaction] {
        guard let accountUUID = UUID(uuidString: accountId) else { return [] }
        // Only the sync window: an Apple Card can carry years of history, and
        // this read now runs on every foregrounding. The provider still drops
        // anything the local-midnight boundary lets through early.
        let start = Transaction.date(fromYYYYMMDD: sinceDay)
        do {
            return try await FinanceStore.shared.transactions(
                query: TransactionQuery(predicate: #Predicate<FinanceKit.Transaction> {
                    $0.accountID == accountUUID && $0.transactionDate >= start
                })
            ).map(AppleWalletTransaction.init)
        } catch {
            // If FinanceKit won't evaluate the date bound, full history still
            // syncs correctly — it's only more work. A genuinely failing read
            // fails here too, so nothing real is swallowed.
            return try await FinanceStore.shared.transactions(
                query: TransactionQuery(predicate: #Predicate<FinanceKit.Transaction> {
                    $0.accountID == accountUUID
                })
            ).map(AppleWalletTransaction.init)
        }
    }

    static func latestBalance(_ balances: [AppleWalletBalance]) -> AppleWalletBalance? {
        balances.max { $0.asOfDate < $1.asOfDate }
    }

    /// One snapshot's balance, picked per account kind. Booked is what's
    /// there or owed; available includes pending — but on a credit card the
    /// available number is the *remaining credit*, not a balance at all, so
    /// there the booked number wins and an available-only snapshot has to be
    /// resolved against the card's limit (Apple Card reports only that shape).
    private static func balance(
        from accountBalance: AccountBalance,
        for account: FinanceKit.Account
    ) -> AppleWalletBalance? {
        let isLiability = account.liabilityAccount != nil
        let selection: (balance: Balance, includesPending: Bool, isRemainingCredit: Bool)?
        selection = switch accountBalance.currentBalance {
        case .booked(let booked): (booked, false, false)
        case .availableAndBooked(let available, let booked):
            isLiability ? (booked, false, false) : (available, true, false)
        case .available(let available): (available, true, isLiability)
        @unknown default: nil
        }
        guard let (balance, includesPending, isRemainingCredit) = selection else { return nil }

        // Remaining credit moves the moment a charge authorizes, so a balance
        // derived from it already includes pending.
        let cents = isRemainingCredit
            ? signedCents(balance).flatMap {
                AppleWalletAccount.owedBalance(
                fromRemainingCredit: $0,
                creditLimitCents: account.liabilityAccount?.creditInformation.creditLimit
                    .flatMap { WalletImportMapper.cents(from: $0.amount) }
                )
            }
            : signedCents(balance)

        return AppleWalletBalance(
            accountId: accountBalance.accountID.uuidString.lowercased(),
            cents: cents,
            asOfDate: balance.asOfDate,
            includesPending: includesPending
        )
    }

    /// Signed cents from one FinanceKit balance: credit is money there, debit
    /// is money owed — which is how an Apple Card's booked balance comes out
    /// negative.
    private static func signedCents(_ balance: Balance) -> Int? {
        guard let cents = WalletImportMapper.cents(from: balance.amount.amount) else { return nil }
        return balance.creditDebitIndicator == .credit ? cents : -cents
    }
}

/// The one place FinanceKit's transaction shape is read. Both consumers — the
/// Tier-1 picker import and bank sync — go through this, so an SDK change
/// lands in exactly one file.
extension AppleWalletTransaction {
    init(_ transaction: FinanceKit.Transaction) {
        self.init(
            id: transaction.id.uuidString,
            amount: transaction.transactionAmount.amount,
            isCredit: transaction.creditDebitIndicator == .credit,
            merchantName: transaction.merchantName,
            description: transaction.transactionDescription,
            status: WalletImportMapper.Status(transaction.status),
            date: transaction.transactionDate
        )
    }
}

extension WalletImportMapper.Status {
    init(_ status: FinanceKit.TransactionStatus) {
        self = switch status {
        case .authorized: .authorized
        case .memo: .memo
        case .pending: .pending
        case .booked: .booked
        case .rejected: .rejected
        @unknown default: .booked
        }
    }
}
