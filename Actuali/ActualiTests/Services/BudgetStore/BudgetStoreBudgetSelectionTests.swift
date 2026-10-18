import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreBudgetSelectionTests {
    private func writeMetadata(_ id: String, cloudFileId: String?, in manager: BudgetFileManager) throws {
        try FileManager.default.createDirectory(
            at: manager.budgetDirectory(for: id), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(BudgetMetadata(
            id: id, budgetName: "Local Name", cloudFileId: cloudFileId, groupId: "group-1",
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: id))
    }

    @Test func selectedRemoteBudgetFollowsMetadataRewrittenUnderTheSameId() throws {
        let (store, manager, root) = makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let budgetId = "budget-\(UUID().uuidString)"

        try writeMetadata(budgetId, cloudFileId: nil, in: manager)
        store.currentBudgetId = budgetId
        #expect(store.selectedRemoteBudget() == nil)

        // A re-download rewrites metadata and reassigns the same id.
        try writeMetadata(budgetId, cloudFileId: "cf-1", in: manager)
        store.currentBudgetId = budgetId
        #expect(store.currentCloudFileId() == "cf-1")

        // Not on the server list yet: the local copy stands in.
        let fallback = try #require(store.selectedRemoteBudget())
        #expect(fallback.id == "cf-1")
        #expect(fallback.name == "Local Name")

        store.remoteBudgets = [
            BudgetStore.RemoteBudget(id: "cf-1", name: "Server Name", groupId: "group-1", isEncrypted: false),
        ]
        #expect(store.selectedRemoteBudget()?.name == "Server Name")

        // A write that leaves the id alone needs an explicit refresh.
        try writeMetadata(budgetId, cloudFileId: "cf-2", in: manager)
        store.refreshCurrentLocalBudget()
        #expect(store.currentCloudFileId() == "cf-2")
    }
}
