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
        let balancesByAccount = Self.latestBalances(balances.compactMap(Self.balance(from:)))
        return accounts.map { account in
            let balance = balancesByAccount[account.id.uuidString.lowercased()]
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

    /// Signed cents from a FinanceKit balance: credit is money there, debit is
    /// money owed — which is how an Apple Card's balance comes out negative.
    static func latestBalances(_ balances: [AppleWalletBalance]) -> [String: AppleWalletBalance] {
        Dictionary(grouping: balances, by: \AppleWalletBalance.accountId)
            .compactMapValues { $0.max { $0.asOfDate < $1.asOfDate } }
    }

    private static func balance(from accountBalance: AccountBalance) -> AppleWalletBalance? {
        let selection: (balance: Balance, includesPending: Bool)? = switch accountBalance.currentBalance {
        case .available(let available): (available, true)
        case .booked(let booked): (booked, false)
        case .availableAndBooked(let available, _): (available, true)
        @unknown default: nil
        }
        guard let (balance, includesPending) = selection else { return nil }
        guard let cents = WalletImportMapper.cents(from: balance.amount.amount) else { return nil }
        return AppleWalletBalance(
            accountId: accountBalance.accountID.uuidString.lowercased(),
            cents: balance.creditDebitIndicator == .credit ? cents : -cents,
            asOfDate: balance.asOfDate,
            includesPending: includesPending
        )
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
