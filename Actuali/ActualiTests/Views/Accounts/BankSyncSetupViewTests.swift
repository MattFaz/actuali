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
}
