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
        let centsByAccount = Dictionary(
            balances.compactMap { balance in
                Self.cents(from: balance).map { (balance.accountID, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return accounts.map { account in
            AppleWalletAccount(
                id: account.id.uuidString,
                name: account.displayName,
                institutionName: account.institutionName,
                balanceCents: centsByAccount[account.id]
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
    private static func cents(from accountBalance: AccountBalance) -> Int? {
        let balance: Balance? = switch accountBalance.currentBalance {
        case .booked(let booked): booked
        case .availableAndBooked(_, let booked): booked
        case .available(let available): available
        @unknown default: nil
        }
        guard let balance,
              let cents = WalletImportMapper.cents(from: balance.amount.amount) else { return nil }
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
