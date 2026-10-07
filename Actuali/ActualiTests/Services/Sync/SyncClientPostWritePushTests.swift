import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actuali

/// Issue #139: Wallet/Shortcuts transactions didn't reach the server until the
/// app was opened. `LogTransactionIntent` runs headless and awaits
/// `ensureBudgetReady()`, which awaits the launch task — and that task ends in
/// `syncOnForeground()`. The write then landed milliseconds after a successful
/// sync, so `automaticSync()`'s 1-second rate limit *dropped* the push. The
/// headless process was suspended before anything else synced, leaving the
/// transaction local-only until the next app launch.
///
/// The rate limit exists to coalesce redundant *pull* syncs (several foreground
/// triggers firing at once); it must never swallow a local write.
struct SyncClientPostWritePushTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.transactions, TestSchema.messagesCrdt)
    }

    /// Every body POSTed to /sync/sync.
    private final class CapturedBodies: Sendable {
        let values = Mutex<[Data]>([])
        var count: Int {
            values.withLock { $0.count }
        }
    }

    /// Answers /sync/sync with a canned, in-sync response (no messages, empty
    /// merkle), recording each request body. The rate-limit window defaults
    /// to open for the whole test so "right after a sync" stays true however
    /// long a starved runner takes between the sync and the write.
    private func makeSyncClient(
        database: BudgetDatabase, recording captured: CapturedBodies,
        session: URLSession? = nil, diagnosticLog: DiagnosticLog = DiagnosticLog(),
        rateLimitWindow: TimeInterval = 3600
    ) async throws -> SyncClient {
        let session = session ?? StubTransport.session { request in
            captured.values.withLock { $0.append(request.bodyData) }
            var response = SyncResponse()
            response.merkle = #"{"hash":0}"#
            return try StubTransport.Response(
                contentType: "application/actual-sync", body: response.serializedData()
            )
        }
        let serverClient = ActualServerClient(session: session, diagnosticLog: diagnosticLog)
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let syncClient = SyncClient(
            serverClient: serverClient, nodeId: "89e0e8e90b203f9e", diagnosticLog: diagnosticLog,
            rateLimitWindow: rateLimitWindow
        )
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func transaction(id: String = "txn-1") -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: 20_260_811,
            amount: -820,
            payeeId: "payee-1",
            payeeName: "Blue Bottle",
            categoryId: nil,
            categoryName: nil,
            notes: nil,
            cleared: true,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: "BLUE BOTTLE COFFEE"
        )
    }

    /// The headless Shortcuts path: launch sync completes, then the intent
    /// writes immediately. The write must still be pushed.
    @Test func writeRightAfterASuccessfulSyncIsStillPushed() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let captured = CapturedBodies()
        let syncClient = try await makeSyncClient(database: database, recording: captured)

        // Launch sync (BudgetStore.init -> loadTask -> syncOnForeground).
        await syncClient.syncNow()
        #expect(captured.count == 1)

        // Intent write, milliseconds later. The push is detached (issue #125),
        // so wait for it the way TransactionLogger does.
        try await syncClient.createTransaction(transaction())
        await syncClient.flushPendingSync()

        // The canned server never echoes the messages back, so its merkle stays
        // empty and fullSync recurses on the diff — hence "more than one" rather
        // than exactly one follow-up POST. What matters is that the write was
        // sent at all: before the fix nothing was, and the transaction sat local
        // -only until the app was next opened.
        let pushes = captured.values.withLock { $0.dropFirst() }
        #expect(!pushes.isEmpty)
        let pushedMessages = try pushes.reduce(0) {
            try $0 + SyncRequest(serializedData: $1).messages.count
        }
        #expect(pushedMessages > 0)
    }

    @Test func cancellingCallerCancelsItsRunningSync() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let log = DiagnosticLog()
        let started = Gate()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let session = StubTransport.session { _ in
            started.open()
            _ = release.wait(timeout: .now() + 60)
            var response = SyncResponse()
            response.merkle = #"{"hash":0}"#
            return try .init(contentType: "application/actual-sync", body: response.serializedData())
        }
        let client = try await makeSyncClient(
            database: database, recording: CapturedBodies(), session: session, diagnosticLog: log
        )
        let caller = Task { await client.syncNow() }
        await started.wait()
        caller.cancel()
        release.signal()
        await caller.value
        await client.cancelPendingSync()

        #expect(await log.snapshot().lastSyncResult == .cancelled)
    }

    @Test func writeDuringForegroundSyncIsStillPushed() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let captured = CapturedBodies()
        let started = Gate()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let session = StubTransport.session { request in
            let first = captured.values.withLock { values in
                values.append(request.bodyData)
                return values.count == 1
            }
            if first {
                started.open()
                _ = release.wait(timeout: .now() + 60)
            }
            var response = SyncResponse()
            response.merkle = #"{"hash":0}"#
            return try .init(contentType: "application/actual-sync", body: response.serializedData())
        }
        let client = try await makeSyncClient(database: database, recording: captured, session: session)
        let foreground = Task { await client.syncNow() }
        await started.wait()
        try await client.createTransaction(transaction())
        release.signal()
        await foreground.value
        await client.flushPendingSync()
        await client.cancelPendingSync()

        let requests = captured.values.withLock { $0 }
        #expect(try SyncRequest(serializedData: requests[0]).messages.isEmpty)
        let followUpMessageCount = try requests.dropFirst().reduce(0) {
            try $0 + SyncRequest(serializedData: $1).messages.count
        }
        #expect(followUpMessageCount > 0)
    }

    /// The rate limit still does its job for pull-only triggers: nothing new
    /// locally means no redundant round trip.
    @Test func redundantPullSyncWithNoLocalWritesIsStillRateLimited() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let captured = CapturedBodies()
        let syncClient = try await makeSyncClient(database: database, recording: captured)

        await syncClient.syncNow()
        #expect(captured.count == 1)

        await syncClient.automaticSync()

        #expect(captured.count == 1)
    }

    /// The window only suppresses a pull while it's open. A zero window is
    /// always elapsed, so this holds without sleeping on the wall clock.
    @Test func pullSyncResumesOnceTheRateLimitWindowHasElapsed() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let captured = CapturedBodies()
        let syncClient = try await makeSyncClient(database: database, recording: captured, rateLimitWindow: 0)

        await syncClient.syncNow()
        #expect(captured.count == 1)

        await syncClient.automaticSync()

        #expect(captured.count == 2)
    }
}
