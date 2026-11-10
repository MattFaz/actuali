import Foundation
import Testing
@testable import Actuali

/// Save-time payee location recording (GH #794): a new transaction records
/// where the phone is, but an edit made later, somewhere else, must not.
@MainActor
struct BudgetStorePayeeLocationRecordingTests {
    private struct FixedPosition: PositionSource {
        let position: Coordinates
        func requestPermission() async -> LocationAuthStatus {
            .granted
        }

        func authorizationStatus() -> LocationAuthStatus {
            .granted
        }

        func fetchPosition() async throws -> Coordinates {
            position
        }
    }

    enum Edit: CaseIterable {
        case plain, plainIntoSplit, splitLines, removeSplit
    }

    private func form(splits: [BudgetStore.SplitLineForm] = []) -> BudgetStore.TransactionForm {
        BudgetStore.TransactionForm(
            accountId: "acct-1",
            type: .expense,
            amount: "10.00",
            payeeName: "Market",
            transferToAccountId: nil,
            categoryId: "cat-food",
            notes: "",
            date: Date(),
            cleared: false,
            splits: splits
        )
    }

    private let twoLines: [BudgetStore.SplitLineForm] = [
        .init(categoryId: "cat-food", amount: "6.00"),
        .init(categoryId: "cat-fun", amount: "4.00"),
    ]

    @Test(arguments: Edit.allCases)
    func editingDoesNotRecordTheCurrentLocation(_ kind: Edit) async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)
        store.setPayeeLocationWritesEnabledForTesting(true)
        store.setLocationProviderForTesting(LocationProvider(
            source: FixedPosition(position: Coordinates(latitude: -33.85, longitude: 151.21))
        ))

        let startsAsSplit = kind == .splitLines || kind == .removeSplit
        try await store.saveTransaction(form(splits: startsAsSplit ? twoLines : []), newId: "tx-1")
        await store.payeeLocationTask?.value
        let payeeId = try #require(store.payees.first { $0.name == "Market" }?.id)
        #expect(try await database.fetchPayeeLocations(payeeId: payeeId).count == 1)

        // Edit from well outside the 500 m dedupe radius.
        store.setLocationProviderForTesting(LocationProvider(
            source: FixedPosition(position: Coordinates(latitude: -37.81, longitude: 144.96))
        ))
        let original = try #require(await database.fetchTransaction(id: "tx-1"))
        var edit = form(splits: kind == .plainIntoSplit || kind == .splitLines ? twoLines : [])
        edit.notes = "edited"
        edit.collapseSplit = kind == .removeSplit
        try await store.saveTransaction(edit, editing: original)
        await store.payeeLocationTask?.value

        #expect(try await database.fetchPayeeLocations(payeeId: payeeId).count == 1)
    }
}
