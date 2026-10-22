import Testing
@testable import Actuali

struct BankSyncSetupViewTests {
    /// Backing out of Apple's consent sheet reports `.denied`, and FinanceKit
    /// never asks again — so the denied row must still lead somewhere (GH #555).
    @Test func deniedWalletAccessOffersSettings() {
        #expect(BankSyncSetupView.walletRow(for: .denied) == .openSettings)
    }

    @Test func otherWalletStatesKeepTheirRows() {
        #expect(BankSyncSetupView.walletRow(for: .authorized) == .accounts)
        #expect(BankSyncSetupView.walletRow(for: .notDetermined) == .connect)
        #expect(BankSyncSetupView.walletRow(for: .unsupported) == .connect)
    }

    /// Wallet data is iPhone-only and currently US-only. Offering the provider
    /// on a device where FinanceKit has nothing would open a connect button
    /// that cannot work — and that calls `FinanceStore` directly, which traps
    /// in an unsigned simulator build.
    @Test func walletProviderHiddenWhereWalletIsUnavailable() {
        #expect(!BankSyncSetupView.showsWalletRow(for: .unsupported))
        #expect(BankSyncSetupView.showsWalletRow(for: .notDetermined))
        #expect(BankSyncSetupView.showsWalletRow(for: .denied))
        #expect(BankSyncSetupView.showsWalletRow(for: .authorized))
    }
}
