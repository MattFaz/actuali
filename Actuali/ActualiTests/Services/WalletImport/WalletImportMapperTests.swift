import Foundation
import Testing
@testable import Actuali

struct WalletImportMapperTests {

    private func candidate(
        id: UUID = UUID(),
        amount: Decimal = Decimal(string: "8.20")!,
        isCredit: Bool = false,
        merchantName: String? = "Blue Bottle",
        transactionDescription: String = "BLUE BOTTLE COFFEE #123",
        status: WalletImportMapper.Status = .booked,
        date: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) -> WalletImportCandidate? {
        WalletImportMapper.candidate(from: AppleWalletTransaction(
            id: id.uuidString,
            amount: amount,
            isCredit: isCredit,
            merchantName: merchantName,
            description: transactionDescription,
            status: status,
            date: date
        ))
    }

    @Test func debitMapsToNegativeCents() throws {
        let mapped = try #require(candidate(amount: Decimal(string: "8.20")!, isCredit: false))
        #expect(mapped.amountCents == -820)
    }

    @Test func creditMapsToPositiveCents() throws {
        let mapped = try #require(candidate(amount: Decimal(string: "8.20")!, isCredit: true))
        #expect(mapped.amountCents == 820)
    }

    @Test func negativeDecimalUsesMagnitude() throws {
        // Sign is carried by creditDebitIndicator, never by the decimal.
        let mapped = try #require(candidate(amount: Decimal(string: "-8.20")!, isCredit: false))
        #expect(mapped.amountCents == -820)
    }

    @Test func subCentAmountRoundsHalfAwayFromZero() throws {
        let mapped = try #require(candidate(amount: Decimal(string: "10.005")!, isCredit: false))
        #expect(mapped.amountCents == -1001)
    }

    @Test func merchantNameIsNormalized() throws {
        let mapped = try #require(candidate(merchantName: "SQ *BLUE BOTTLE #123"))
        #expect(mapped.payeeName == "Blue Bottle")
    }

    @Test func missingMerchantFallsBackToDescription() throws {
        let mapped = try #require(candidate(
            merchantName: nil, transactionDescription: "TST* JOES DINER"))
        #expect(mapped.payeeName == "Joes Diner")
    }

    @Test func emptyMerchantFallsBackToDescription() throws {
        let mapped = try #require(candidate(
            merchantName: "", transactionDescription: "JOES DINER"))
        #expect(mapped.payeeName == "Joes Diner")
    }

    @Test func whitespaceMerchantFallsBackToDescription() throws {
        let mapped = try #require(candidate(
            merchantName: "   ", transactionDescription: "JOES DINER"))
        #expect(mapped.payeeName == "Joes Diner")
    }

    @Test func bookedIsCleared() throws {
        let mapped = try #require(candidate(status: .booked))
        #expect(mapped.cleared)
    }

    @Test func pendingAndAuthorizedAreUncleared() throws {
        #expect(try #require(candidate(status: .pending)).cleared == false)
        #expect(try #require(candidate(status: .authorized)).cleared == false)
    }

    @Test func rejectedIsDropped() {
        #expect(candidate(status: .rejected) == nil)
    }

    @Test func financialIdIsLowercasedUUID() throws {
        let id = UUID()
        let mapped = try #require(candidate(id: id))
        #expect(mapped.id == id.uuidString.lowercased())
    }

    @Test func datePassesThrough() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let mapped = try #require(candidate(date: date))
        #expect(mapped.date == date)
    }
}
