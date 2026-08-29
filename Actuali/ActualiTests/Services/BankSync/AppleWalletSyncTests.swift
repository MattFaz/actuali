import Foundation
import Testing
@testable import Actuali

struct AppleWalletSyncTests {

    private func transaction(
        id: String = "11111111-1111-1111-1111-111111111111",
        amount: Decimal = Decimal(string: "33.45")!,
        isCredit: Bool = false,
        merchantName: String? = "Blue Bottle",
        description: String = "BLUE BOTTLE COFFEE",
        status: WalletImportMapper.Status = .booked,
        date: Date = Date()
    ) -> AppleWalletTransaction {
        AppleWalletTransaction(
            id: id, amount: amount, isCredit: isCredit, merchantName: merchantName,
            description: description, status: status, date: date
        )
    }

    // MARK: - Candidate mapping

    @Test func aPurchaseBecomesABookedOutflow() throws {
        let date = Date()
        let candidate = try #require(BankSyncCandidate(appleWallet: transaction(date: date)))

        #expect(candidate.importedId == "11111111-1111-1111-1111-111111111111")
        #expect(candidate.amount == -3345)
        #expect(candidate.date == Transaction.yyyymmdd(from: date))
        #expect(candidate.payeeName == "Blue Bottle")
        #expect(candidate.notes == "BLUE BOTTLE COFFEE")
        #expect(candidate.cleared)
    }

    @Test func aCreditBecomesAnInflow() throws {
        let candidate = try #require(BankSyncCandidate(appleWallet: transaction(isCredit: true)))
        #expect(candidate.amount == 3345)
    }

    @Test func pendingAndAuthorizedImportUncleared() throws {
        let pending = try #require(BankSyncCandidate(appleWallet: transaction(status: .pending)))
        let authorized = try #require(BankSyncCandidate(appleWallet: transaction(status: .authorized)))
        #expect(!pending.cleared)
        #expect(!authorized.cleared)
    }

    @Test func aRejectedTransactionIsDropped() {
        #expect(BankSyncCandidate(appleWallet: transaction(status: .rejected)) == nil)
    }

    /// Wallet merchant strings carry the same processor noise as the Tier-1
    /// picker import; both must file "SQ *X #123" under the same payee.
    @Test func merchantNoiseIsStrippedLikeThePickerImport() throws {
        let candidate = try #require(BankSyncCandidate(
            appleWallet: transaction(merchantName: "SQ *BLUE BOTTLE #123")
        ))
        #expect(candidate.payeeName == "Blue Bottle")
    }

    @Test func aMissingMerchantFallsBackToTheDescription() throws {
        let candidate = try #require(BankSyncCandidate(
            appleWallet: transaction(merchantName: nil, description: "Corner Store")
        ))
        #expect(candidate.payeeName == "Corner Store")
    }

    /// Same escaping as every other bank-sync note, so a "#" in a Wallet
    /// description doesn't silently become a tag.
    @Test func notesEscapeHashes() throws {
        let candidate = try #require(BankSyncCandidate(
            appleWallet: transaction(description: "COFFEE #4")
        ))
        #expect(candidate.notes == "COFFEE ##4")
    }

    @Test func remoteAccountCarriesTheFinanceKitSource() {
        let account = AppleWalletAccount(
            id: "22222222-2222-2222-2222-222222222222",
            name: "Apple Card",
            institutionName: "Apple",
            balanceCents: -50000
        )
        let remote = account.remoteAccount
        #expect(remote.source == .financeKit)
        #expect(remote.id == account.id)
        #expect(remote.institutionId == "Apple")
        #expect(remote.institutionName == "Apple")
        #expect(remote.balanceCents == -50000)
    }

    // MARK: - Provider

    private static let cardId = "22222222-2222-2222-2222-222222222222"

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date())!
    }

    @Test func downloadCoversOnlyAccountsTheWalletHas() async throws {
        let store = StubWalletStore(
            accountsValue: [AppleWalletAccount(
                id: Self.cardId, name: "Apple Card", institutionName: "Apple", balanceCents: -50000
            )],
            transactionsByAccount: [Self.cardId: [transaction()]]
        )
        let startDay = Transaction.yyyymmdd(from: daysAgo(89))

        let set = try await AppleWalletProvider(store: store).download([
            BankSyncTarget(externalId: Self.cardId, startDay: startDay),
            BankSyncTarget(externalId: "not-in-this-wallet", startDay: startDay)
        ])

        // The unknown account is left out entirely, so the caller reports it.
        #expect(set.byAccount.count == 1)
        let download = try #require(set.byAccount[Self.cardId])
        #expect(download.candidates.count == 1)
        #expect(download.currentBalanceCents == -50000)
        #expect(download.status == "ok")
    }

    /// The store hands over full history; the provider keeps only the sync
    /// window, the same way the SimpleFIN providers do.
    @Test func downloadDropsTransactionsBeforeTheStartDay() async throws {
        let store = StubWalletStore(
            accountsValue: [AppleWalletAccount(
                id: Self.cardId, name: "Apple Card", institutionName: "Apple", balanceCents: nil
            )],
            transactionsByAccount: [Self.cardId: [
                transaction(id: "11111111-1111-1111-1111-111111111111", date: daysAgo(2)),
                transaction(id: "33333333-3333-3333-3333-333333333333", date: daysAgo(30))
            ]]
        )

        let set = try await AppleWalletProvider(store: store).download([
            BankSyncTarget(externalId: Self.cardId, startDay: Transaction.yyyymmdd(from: daysAgo(7)))
        ])

        let download = try #require(set.byAccount[Self.cardId])
        #expect(download.candidates.map(\.importedId) == ["11111111-1111-1111-1111-111111111111"])
    }
}
