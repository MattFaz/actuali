import Foundation
import Synchronization
@testable import Actuali

/// A canned Wallet, standing in for FinanceKit off-device. Shared by the
/// wallet-sync suites and the mixed-source tests in
/// `BudgetStoreBankSyncTests`.
struct StubWalletStore: AppleWalletReading {
    struct ReadFailed: Error {}

    /// Background delivery requests, in order. A class so a copy of the stub
    /// handed to the store still reports into the test's instance.
    final class DeliveryLog: Sendable {
        let requests = Mutex<[Bool]>([])
    }

    var availabilityValue: AppleWalletAvailability = .authorized
    var accountsValue: [AppleWalletAccount] = []
    var transactionsByAccount: [String: [AppleWalletTransaction]] = [:]
    /// When set, `accounts()` throws — a Wallet read gone wrong.
    var throwsOnAccounts = false
    /// What `setBackgroundDelivery` reports; false mimics a pre-iOS 26 device.
    var backgroundDeliverySupported = true
    let deliveryLog = DeliveryLog()

    func availability() async -> AppleWalletAvailability {
        availabilityValue
    }

    func requestAccess() async throws -> Bool {
        availabilityValue == .authorized
    }

    func accounts() async throws -> [AppleWalletAccount] {
        if throwsOnAccounts {
            throw ReadFailed()
        }
        return accountsValue
    }

    /// sinceDay is deliberately ignored: the provider must hold its own window
    /// filter even when a store over-serves, which these tests exercise.
    func transactions(accountId: String, sinceDay: Int) async throws -> [AppleWalletTransaction] {
        transactionsByAccount[accountId] ?? []
    }

    func setBackgroundDelivery(enabled: Bool) -> Bool {
        guard backgroundDeliverySupported else { return false }
        deliveryLog.requests.withLock { $0.append(enabled) }
        return true
    }
}
