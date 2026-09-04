import Foundation
import Testing
@testable import Actuali

struct BankSyncReconcilerTests {

    private func candidate(
        importedId: String = "sf-1",
        date: Int = 20240310,
        amount: Int = -1250,
        payeeName: String = "Blue Bottle",
        payeeId: String? = nil,
        notes: String? = nil,
        cleared: Bool = true
    ) -> BankSyncCandidate {
        BankSyncCandidate(
            importedId: importedId, date: date, amount: amount,
            payeeName: payeeName, payeeId: payeeId, notes: notes, cleared: cleared
        )
    }

    private func existing(
        id: String = "tx-1",
        date: Int = 20240310,
        amount: Int = -1250,
        payeeId: String? = nil,
        importedId: String? = nil,
        importedPayee: String? = nil,
        notes: String? = nil,
        cleared: Bool = false,
        reconciled: Bool = false,
        tombstone: Bool = false
    ) -> BankSyncExistingTransaction {
        BankSyncExistingTransaction(
            id: id, date: date, amount: amount, payeeId: payeeId, importedId: importedId,
            importedPayee: importedPayee, notes: notes, cleared: cleared,
            reconciled: reconciled, tombstone: tombstone
        )
    }

    // MARK: - Nothing to match against

    @Test func downloadsWithNothingToMatchAreInserts() {
        let plan = BankSyncReconciler.plan(candidates: [candidate()], existing: [])

        #expect(plan.inserts.count == 1)
        #expect(plan.updates.isEmpty)
        #expect(plan.unchanged == 0)
    }

    // MARK: - Pass 1: the provider's transaction id

    @Test func aTransactionWeAlreadyImportedIsLeftAlone() {
        let plan = BankSyncReconciler.plan(
            candidates: [candidate(importedId: "sf-1")],
            existing: [existing(importedId: "sf-1", importedPayee: "Blue Bottle", cleared: true)]
        )

        #expect(plan.isEmpty)
        #expect(plan.unchanged == 1)
    }

    /// The common re-sync: a pending charge posts, so the same transaction
    /// comes back booked and the row it already made should clear.
    @Test func aPendingTransactionThatPostsClearsTheRowItMade() throws {
        let plan = BankSyncReconciler.plan(
            candidates: [candidate(importedId: "sf-1", cleared: true)],
            existing: [existing(importedId: "sf-1", importedPayee: "Blue Bottle", cleared: false)]
        )

        #expect(plan.inserts.isEmpty)
        let update = try #require(plan.updates.first)
        #expect(update.existingId == "tx-1")
        #expect(update.cleared)
    }

    @Test func aLiveIdMatchWinsOverADeletedOne() throws {
        let plan = BankSyncReconciler.plan(
            candidates: [candidate(cleared: true)],
            existing: [
                existing(id: "tx-deleted", importedId: "sf-1", tombstone: true),
                existing(id: "tx-live", importedId: "sf-1")
            ],
            reimportDeleted: false
        )

        #expect(try #require(plan.updates.first).existingId == "tx-live")
        #expect(plan.updates.first?.cleared == true)
    }

    /// The id match beats the fuzzy window even when the window has a nearer
    /// row: it's the only match the provider actually vouched for.
    @Test func theIdMatchWinsOverACloserDate() throws {
        let plan = BankSyncReconciler.plan(
            candidates: [candidate(importedId: "sf-1", date: 20240310)],
            existing: [
                existing(id: "tx-near", date: 20240310),
                existing(id: "tx-far", date: 20240313, importedId: "sf-1")
            ]
        )

        #expect(plan.updates.map(\.existingId) == ["tx-far"])
    }

    // MARK: - Pass 2 and 3: the fuzzy window

    /// The case this whole pass exists for: someone entered a purchase by hand
    /// before the bank posted it.
    @Test func aHandEnteredTransactionIsAdoptedRatherThanDuplicated() throws {
        let plan = BankSyncReconciler.plan(
            candidates: [candidate(importedId: "sf-1", date: 20240310, notes: "Coffee")],
            existing: [existing(id: "tx-manual", date: 20240308, payeeId: "payee-1")]
        )

        #expect(plan.inserts.isEmpty)
        let update = try #require(plan.updates.first)
        #expect(update.existingId == "tx-manual")
        #expect(update.importedId == "sf-1")
        #expect(update.importedPayee == "Blue Bottle")
        // What the person already filled in stays theirs.
        #expect(update.payeeId == "payee-1")
        #expect(update.notes == "Coffee")
    }

    @Test func matchingLooksSevenDaysEitherSideAndNoFurther() {
        let inWindow = BankSyncReconciler.plan(
            candidates: [candidate(date: 20240310)],
            existing: [existing(date: 20240303)]
        )
        let outOfWindow = BankSyncReconciler.plan(
            candidates: [candidate(date: 20240310)],
            existing: [existing(date: 20240302)]
        )

        #expect(inWindow.updates.count == 1)
        #expect(outOfWindow.inserts.count == 1)
        #expect(outOfWindow.updates.isEmpty)
    }

    @Test func differentAmountsNeverMatch() {
        let plan = BankSyncReconciler.plan(
            candidates: [candidate(amount: -1250)],
            existing: [existing(amount: -1251)]
        )

        #expect(plan.inserts.count == 1)
    }

    /// Pass 2 runs across every download before pass 3, so a same-payee match
    /// can't be stolen by an earlier download that only matched on amount.
    @Test func aSamePayeeMatchOutranksAnEarlierVaguerOne() throws {
        let plan = BankSyncReconciler.plan(
            candidates: [
                candidate(importedId: "sf-1", date: 20240310, payeeName: "Other", payeeId: "payee-2"),
                candidate(importedId: "sf-2", date: 20240310, payeeName: "Blue Bottle", payeeId: "payee-1")
            ],
            existing: [existing(id: "tx-1", date: 20240310, payeeId: "payee-1")]
        )

        #expect(plan.updates.count == 1)
        let update = try #require(plan.updates.first)
        #expect(update.importedId == "sf-2")
        #expect(update.existingId == "tx-1")
        // The one that lost the row is new after all.
        #expect(plan.inserts.map(\.importedId) == ["sf-1"])
    }

    @Test func oneLocalRowIsClaimedByAtMostOneDownload() {
        let plan = BankSyncReconciler.plan(
            candidates: [
                candidate(importedId: "sf-1", date: 20240310),
                candidate(importedId: "sf-2", date: 20240310)
            ],
            existing: [existing(id: "tx-1", date: 20240310)]
        )

        #expect(plan.updates.count == 1)
        #expect(plan.inserts.count == 1)
    }

    @Test func theNearestDateInTheWindowIsMatchedFirst() throws {
        let plan = BankSyncReconciler.plan(
            candidates: [candidate(date: 20240310)],
            existing: [
                existing(id: "tx-far", date: 20240305),
                existing(id: "tx-near", date: 20240311)
            ]
        )

        #expect(try #require(plan.updates.first).existingId == "tx-near")
    }

    /// Providers reissue ids for the same transaction (a pending charge that
    /// posts, most often), so bank-sync matching deliberately doesn't skip
    /// rows that already carry a different one.
    @Test func aRowWithADifferentProviderIdCanStillMatch() throws {
        let plan = BankSyncReconciler.plan(
            candidates: [candidate(importedId: "sf-new", date: 20240310)],
            existing: [existing(id: "tx-1", date: 20240310, importedId: "sf-old")]
        )

        #expect(plan.inserts.isEmpty)
        #expect(try #require(plan.updates.first).importedId == "sf-new")
    }

    // MARK: - Locked rows

    @Test func reconciledTransactionsAreNeverTouched() {
        let plan = BankSyncReconciler.plan(
            candidates: [candidate(importedId: "sf-1")],
            existing: [existing(reconciled: true)]
        )

        #expect(plan.isEmpty)
        #expect(plan.unchanged == 1)
    }

    // MARK: - Day arithmetic

    @Test(arguments: [
        (20240301, 20240229, 1),
        (20250101, 20240101, 366),
        (20240310, 20231212, 89)
    ])
    func dayDistanceMeasuresAcrossMonthAndYearBoundaries(
        _ from: Int, _ to: Int, _ expected: Int
    ) {
        #expect(BankSyncReconciler.dayDistance(from, to) == expected)
    }
}

struct BankSyncCandidateNormalizationTests {

    private func transaction(_ json: String) throws -> SimpleFINTransaction {
        try JSONDecoder().decode(SimpleFINTransaction.self, from: Data(json.utf8))
    }

    @Test func takesThePayeeFromPayeeAndTheNotesFromDescription() throws {
        let candidate = try #require(BankSyncCandidate(simpleFIN: transaction("""
        {"id": "sf-1", "posted": 1709253000, "amount": "-33.45",
         "payee": "Uncle Frank", "description": "Uncle Frank's Bait Shop"}
        """)))

        #expect(candidate.importedId == "sf-1")
        #expect(candidate.date == 20240301)
        #expect(candidate.amount == -3345)
        #expect(candidate.payeeName == "Uncle Frank")
        #expect(candidate.notes == "Uncle Frank's Bait Shop")
        #expect(candidate.cleared)
        #expect(candidate.payeeId == nil)
    }

    /// Not every bridge fills in `payee`, and importing a nameless payee would
    /// be worse than reusing the description.
    @Test func fallsBackToTheDescriptionWhenThereIsNoPayee() throws {
        let candidate = try #require(BankSyncCandidate(simpleFIN: transaction("""
        {"id": "sf-1", "posted": 1709253000, "amount": "-1.00", "description": "ACME CORP  #4821"}
        """)))

        #expect(candidate.payeeName == "ACME CORP  #4821")
    }

    /// A "#" in a bank's own description would otherwise read as a tag.
    @Test func escapesHashesInTheNotes() throws {
        let candidate = try #require(BankSyncCandidate(simpleFIN: transaction("""
        {"id": "sf-1", "posted": 1709253000, "amount": "-1.00", "description": "ACME #4821"}
        """)))

        #expect(candidate.notes == "ACME ##4821")
        #expect(!TagFilter.notesContainTag(candidate.notes ?? "", tag: "#4821", caseSensitive: true))
    }

    @Test func pendingTransactionsImportUnclearedAndDatedWhenTheyHappened() throws {
        let candidate = try #require(BankSyncCandidate(simpleFIN: transaction("""
        {"id": "sf-1", "posted": 0, "pending": true, "transacted_at": 1709253000,
         "amount": "-1.00", "description": "Coffee"}
        """)))

        #expect(!candidate.cleared)
        #expect(candidate.date == 20240301)
    }

    @Test func transactionsWithAnUnreadableAmountAreSkipped() throws {
        #expect(try BankSyncCandidate(simpleFIN: transaction("""
        {"id": "sf-1", "posted": 1709253000, "amount": "not-a-number", "description": "Coffee"}
        """)) == nil)
    }
}
