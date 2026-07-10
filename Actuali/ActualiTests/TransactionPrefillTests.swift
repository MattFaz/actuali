import Foundation
import Testing
@testable import Actuali

struct TransactionPrefillTests {

    @Test func roundTripsAllFields() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let prefill = TransactionPrefill(accountId: "acct-1", payee: "Blue Bottle", amountCents: 450, date: date)
        let decoded = TransactionPrefill(userInfo: prefill.userInfo)
        #expect(decoded?.accountId == "acct-1")
        #expect(decoded?.payee == "Blue Bottle")
        #expect(decoded?.amountCents == 450)
        #expect(decoded?.date == date)
    }

    @Test func roundTripsOptionalFieldsAsNil() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let prefill = TransactionPrefill(accountId: nil, payee: "", amountCents: nil, date: date)
        let decoded = TransactionPrefill(userInfo: prefill.userInfo)
        #expect(decoded != nil)
        #expect(decoded?.accountId == nil)
        #expect(decoded?.payee == "")
        #expect(decoded?.amountCents == nil)
    }

    @Test func returnsNilForForeignUserInfo() {
        #expect(TransactionPrefill(userInfo: [:]) == nil)
        #expect(TransactionPrefill(userInfo: ["unrelated": true]) == nil)
    }
}
