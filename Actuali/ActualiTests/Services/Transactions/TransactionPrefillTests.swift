import Foundation
import Testing
@testable import Actuali

struct TransactionPrefillTests {

    @Test func roundTripsAllFields() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let prefill = TransactionPrefill(
            accountId: "acct-1",
            payee: "Blue Bottle",
            amountCents: 450,
            date: date,
            notes: "Team coffee",
            categoryId: "cat-7",
            isIncome: true,
            cleared: true
        )
        let decoded = TransactionPrefill(userInfo: prefill.userInfo)
        #expect(decoded?.accountId == "acct-1")
        #expect(decoded?.payee == "Blue Bottle")
        #expect(decoded?.amountCents == 450)
        #expect(decoded?.date == date)
        #expect(decoded?.notes == "Team coffee")
        #expect(decoded?.categoryId == "cat-7")
        #expect(decoded?.isIncome == true)
        #expect(decoded?.cleared == true)
    }

    @Test func roundTripsOptionalFieldsAsNil() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let prefill = TransactionPrefill(accountId: nil, payee: "", amountCents: nil, date: date)
        let decoded = TransactionPrefill(userInfo: prefill.userInfo)
        #expect(decoded != nil)
        #expect(decoded?.accountId == nil)
        #expect(decoded?.payee == "")
        #expect(decoded?.amountCents == nil)
        #expect(decoded?.categoryId == nil)
    }

    @Test func decodesLegacyPayloadWithoutNewKeys() {
        // A notification scheduled by an older build carries none of the
        // notes/category/type keys; decoding must fall back to the same
        // defaults the old form used.
        let userInfo: [AnyHashable: Any] = [
            "kind": "com.mfazz.Actuali.transactionPrefill",
            "payee": "Blue Bottle",
            "date": 1_750_000_000.0,
        ]
        let decoded = TransactionPrefill(userInfo: userInfo)
        #expect(decoded != nil)
        #expect(decoded?.notes == "")
        #expect(decoded?.categoryId == nil)
        #expect(decoded?.isIncome == false)
        #expect(decoded?.cleared == false)
    }

    @Test func returnsNilForForeignUserInfo() {
        #expect(TransactionPrefill(userInfo: [:]) == nil)
        #expect(TransactionPrefill(userInfo: ["unrelated": true]) == nil)
    }
}
