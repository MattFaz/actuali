import Foundation
@testable import Actuali

/// A canned Wallet, standing in for FinanceKit off-device. Shared by the
/// wallet-sync suites and the mixed-source tests in
/// `BudgetStoreBankSyncTests`.
struct StubWalletStore: AppleWalletReading {
    struct ReadFailed: Error {}

    var availabilityValue: AppleWalletAvailability = .authorized
    var accountsValue: [AppleWalletAccount] = []
    var transactionsByAccount: [String: [AppleWalletTransaction]] = [:]
    /// When set, `accounts()` throws — a Wallet read gone wrong.
    var throwsOnAccounts = false

    func availability() async -> AppleWalletAvailability { availabilityValue }
    func requestAccess() async throws -> Bool { availabilityValue == .authorized }
    func accounts() async throws -> [AppleWalletAccount] {
        if throwsOnAccounts { throw ReadFailed() }
        return accountsValue
    }
    func transactions(accountId: String) async throws -> [AppleWalletTransaction] {
        transactionsByAccount[accountId] ?? []
    }
}
