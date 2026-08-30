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
        guard FinanceStore.isDataAvailable(.financialData) else { return .unsupported }
        // authorizationStatus throws in builds without the FinanceKit
        // entitlement; treated as not-determined so the setup screen's
        // connect button is what surfaces the real error.
        switch try? await FinanceStore.shared.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    func requestAccess() async throws -> Bool {
        try await FinanceStore.shared.requestAuthorization() == .authorized
    }

    func accounts() async throws -> [AppleWalletAccount] {
        let accounts = try await FinanceStore.shared.accounts(query: AccountQuery())
        let balances = try await FinanceStore.shared.accountBalances(query: AccountBalanceQuery())
        return accounts.map { account in
            // Which of a snapshot's numbers is the balance depends on the
            // account it belongs to, so snapshots are mapped per account.
            let snapshots = balances
                .filter { $0.accountID == account.id }
                .compactMap { Self.balance(from: $0, for: account) }
            let balance = Self.latestBalances(snapshots)[account.id.uuidString.lowercased()]
            return AppleWalletAccount(
                id: account.id.uuidString,
                name: account.displayName,
                institutionName: account.institutionName,
                balanceCents: balance?.cents,
                balanceIncludesPending: balance?.includesPending ?? false
            )
        }
    }

    func transactions(accountId: String) async throws -> [AppleWalletTransaction] {
        guard let accountUUID = UUID(uuidString: accountId) else { return [] }
        // ponytail: fetches the account's full history every sync and lets the
        // caller drop what's outside the window. FinanceKit reads are local, so
        // this holds up to years of Apple Card history; the upgrade path is a
        // transactionDate bound in the predicate.
        let transactions = try await FinanceStore.shared.transactions(
            query: TransactionQuery(predicate: #Predicate<FinanceKit.Transaction> {
                $0.accountID == accountUUID
            })
        )
        return transactions.map(AppleWalletTransaction.init)
    }

    static func latestBalances(_ balances: [AppleWalletBalance]) -> [String: AppleWalletBalance] {
        Dictionary(grouping: balances, by: \AppleWalletBalance.accountId)
            .compactMapValues { $0.max { $0.asOfDate < $1.asOfDate } }
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
        guard let (balance, includesPending, isRemainingCredit) = selection,
              let signed = signedCents(balance) else { return nil }

        // Remaining credit moves the moment a charge authorizes, so a balance
        // derived from it already includes pending.
        let cents = isRemainingCredit
            ? AppleWalletAccount.owedBalance(
                fromRemainingCredit: signed,
                creditLimitCents: account.liabilityAccount?.creditInformation.creditLimit
                    .flatMap { WalletImportMapper.cents(from: $0.amount) }
            )
            : signed
        guard let cents else { return nil }

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
