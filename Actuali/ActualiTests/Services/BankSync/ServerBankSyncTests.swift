import Foundation
import Testing
@testable import Actuali

struct ServerBankSyncDecodingTests {

    private func decode(_ json: String) throws -> ServerBankSyncDownloads {
        try JSONDecoder().decode(ServerBankSyncDownloads.self, from: Data(json.utf8))
    }

    @Test func decodesTheAccountKeyedPayload() throws {
        let downloads = try decode("""
        {"sf-1": {"startingBalance": 10023,
                  "transactions": {"all": [
                    {"transactionId": "t1", "date": "2024-03-01", "payeeName": "Blue Bottle",
                     "notes": "BLUE BOTTLE", "booked": true,
                     "transactionAmount": {"amount": "-33.45", "currency": "USD"}}
                  ]}},
         "sf-2": {"startingBalance": 500, "transactions": {"all": []}}}
        """)

        #expect(downloads.failure == nil)
        #expect(downloads.errors.isEmpty)
        #expect(downloads.accounts.count == 2)
        #expect(downloads.accounts["sf-1"]?.startingBalance == 10023)
        #expect(downloads.accounts["sf-1"]?.transactions?.all?.count == 1)
        #expect(downloads.accounts["sf-2"]?.transactions?.all?.isEmpty == true)
    }

    /// `errors` sits alongside the account keys, so dynamic-key decoding has to
    /// know not to read it as an account.
    @Test func separatesPerAccountErrorsFromAccountData() throws {
        let downloads = try decode("""
        {"sf-1": {"startingBalance": 100, "transactions": {"all": []}},
         "errors": {"sf-2": [{"error_type": "ACCOUNT_MISSING", "error_code": "ACCOUNT_MISSING",
                              "reason": "The account was not found."}]}}
        """)

        #expect(downloads.accounts.keys.sorted() == ["sf-1"])
        #expect(downloads.errors["sf-2"]?.first?.errorCode == "ACCOUNT_MISSING")
        #expect(downloads.errors["sf-2"]?.first?.bankSyncStatus == "account-missing")
    }

    /// A rejected access key replaces the whole payload with the error object
    /// rather than putting one inside it.
    @Test func recognisesAWholeRequestFailure() throws {
        let downloads = try decode("""
        {"error_type": "INVALID_ACCESS_TOKEN", "error_code": "INVALID_ACCESS_TOKEN",
         "status": "rejected", "reason": "Invalid SimpleFIN access token."}
        """)

        #expect(downloads.failure?.errorCode == "INVALID_ACCESS_TOKEN")
        #expect(downloads.failure?.bankSyncStatus == "reauth-required")
        #expect(downloads.accounts.isEmpty)
    }

    /// An account the bridge didn't return comes back as null.
    @Test func toleratesANullAccountEntry() throws {
        let downloads = try decode(#"{"sf-1": null}"#)

        #expect(downloads.accounts.isEmpty)
        #expect(downloads.failure == nil)
    }

    @Test(arguments: [
        ("ITEM_LOGIN_REQUIRED", "reauth-required"),
        ("ACCOUNT_NEEDS_ATTENTION", "attention-required"),
        ("RATE_LIMIT_EXCEEDED", "rate-limit-exceeded"),
        ("TIMED_OUT", "timed-out"),
        ("SOMETHING_ELSE", "failed")
    ])
    func mapsErrorCodesOntoActualsStatusVocabulary(_ code: String, _ expected: String) throws {
        let downloads = try decode("""
        {"errors": {"sf-1": [{"error_code": "\(code)"}]}}
        """)

        #expect(downloads.errors["sf-1"]?.first?.bankSyncStatus == expected)
    }
}

struct ServerBankSyncNormalizationTests {

    private func transaction(_ json: String) throws -> ServerBankSyncTransaction {
        try JSONDecoder().decode(ServerBankSyncTransaction.self, from: Data(json.utf8))
    }

    @Test func readsTheServersAlreadyNormalizedShape() throws {
        let candidate = try #require(BankSyncCandidate(serverBankSync: transaction("""
        {"transactionId": "t1", "date": "2024-03-01", "payeeName": "Blue Bottle",
         "notes": "BLUE BOTTLE #12", "booked": true,
         "transactionAmount": {"amount": "-33.45", "currency": "USD"}}
        """)))

        #expect(candidate.importedId == "t1")
        #expect(candidate.date == 20240301)
        #expect(candidate.amount == -3345)
        #expect(candidate.payeeName == "Blue Bottle")
        // Hashes are escaped here too, the same as on the direct path.
        #expect(candidate.notes == "BLUE BOTTLE ##12")
        #expect(candidate.cleared)
    }

    @Test func pendingTransactionsStayUncleared() throws {
        let candidate = try #require(BankSyncCandidate(serverBankSync: transaction("""
        {"transactionId": "t1", "date": "2024-03-01", "payeeName": "Corner Store",
         "booked": false, "transactionAmount": {"amount": "-12.00"}}
        """)))

        #expect(!candidate.cleared)
    }

    @Test func fallsBackToTheNotesWhenThereIsNoPayeeName() throws {
        let candidate = try #require(BankSyncCandidate(serverBankSync: transaction("""
        {"transactionId": "t1", "date": "2024-03-01", "notes": "ACME CORP",
         "booked": true, "transactionAmount": {"amount": "-1.00"}}
        """)))

        #expect(candidate.payeeName == "ACME CORP")
    }

    @Test(arguments: [
        #"{"date": "2024-03-01", "transactionAmount": {"amount": "-1.00"}}"#,      // no id
        #"{"transactionId": "t1", "transactionAmount": {"amount": "-1.00"}}"#,     // no date
        #"{"transactionId": "t1", "date": "not-a-date", "transactionAmount": {"amount": "-1.00"}}"#,
        #"{"transactionId": "t1", "date": "2024-03-01"}"#                          // no amount
    ])
    func skipsTransactionsMissingWhatAnImportNeeds(_ json: String) throws {
        #expect(BankSyncCandidate(serverBankSync: transaction(json)) == nil)
    }

    @Test func isoDatesRoundTrip() {
        #expect(BankSyncReconciler.day(fromISO: "2024-03-01") == 20240301)
        #expect(BankSyncReconciler.isoString(from: 20240301) == "2024-03-01")
        #expect(BankSyncReconciler.day(fromISO: "2024-3-1") == 20240301)
        #expect(BankSyncReconciler.day(fromISO: "2024-03") == nil)
        #expect(BankSyncReconciler.day(fromISO: "2024-13-01") == nil)
    }
}
