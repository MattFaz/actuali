import Foundation
import Testing
@testable import Actuali

struct DiagnosticLogTests {
    private func formattedReport(from snapshot: DiagnosticLogSnapshot) -> String {
        snapshot.entries
            .map { "\($0.date.ISO8601Format()) \($0.message)" }
            .joined(separator: "\n")
    }

    @Test func keepsOnlyMostRecentEntries() async {
        let log = DiagnosticLog(capacity: 2)

        await log.recordSyncStarted()
        await log.recordSyncResponseMessageCount(1)
        await log.recordSyncFinished(.success)

        let snapshot = await log.snapshot()
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries[0].message == "SYNC response-messages=1")
        #expect(snapshot.entries[1].message.hasPrefix("SYNC finished result=success"))
    }

    @Test func networkMetadataNeverContainsRequestBodyOrHeaderValues() async throws {
        let log = DiagnosticLog()
        let session = StubTransport.session { request in
            #expect(request.value(forHTTPHeaderField: "X-Proxy-Secret") == "proxy-secret")
            let body = String(data: request.bodyData, encoding: .utf8) ?? ""
            #expect(body.contains("hunter2"))

            return .init(
                status: 500,
                contentType: "application/json",
                body: Data(#"{"reason":"secret-budget-data"}"#.utf8)
            )
        }
        let client = ActualServerClient(session: session, diagnosticLog: log)

        try await client.configure(serverURL: "https://budget.example.com")
        await client.setCustomHeaders([("X-Proxy-Secret", "proxy-secret")])

        do {
            _ = try await client.login(password: "hunter2")
        } catch {}

        let report = await formattedReport(from: log.snapshot())
        #expect(report.contains("method=POST"))
        #expect(report.contains("path=/account/login"))
        #expect(report.contains("status=500"))
        #expect(report.contains("error=http(500)"))
        #expect(report.contains("duration="))
        let snapshot = await log.snapshot()
        #expect(snapshot.customHeadersConfigured)
        #expect(!report.contains("hunter2"))
        #expect(!report.contains("proxy-secret"))
        #expect(!report.contains("secret-budget-data"))
    }

    @Test func transportFailuresRecordSafeErrorCode() async throws {
        let log = DiagnosticLog()
        let client = ActualServerClient(
            session: StubTransport.session { _ in
                throw URLError(.secureConnectionFailed)
            },
            diagnosticLog: log
        )

        try await client.configure(serverURL: "https://budget.example.com")

        do {
            _ = try await client.login(password: "not-a-real-password")
        } catch {}

        let report = await formattedReport(from: log.snapshot())
        #expect(report.contains("method=POST"))
        #expect(report.contains("path=/account/login"))
        #expect(report.contains("status=none"))
        #expect(
            report.contains(
                "error=tls(\(URLError.Code.secureConnectionFailed.rawValue))"
            )
        )
        #expect(!report.contains("not-a-real-password"))
    }

    @Test func syncFailureRecordsLifecycle() async {
        let log = DiagnosticLog()
        let client = SyncClient(
            serverClient: ActualServerClient(diagnosticLog: log),
            diagnosticLog: log
        )

        let result = await client.automaticSync()
        #expect(!result)
        await client.cancelPendingSync()

        let report = await formattedReport(from: log.snapshot())
        #expect(report.contains("SYNC started"))
        #expect(report.contains("SYNC finished result=failed"))
    }

    @Test func manualResetRecordsResyncTrigger() async {
        let log = DiagnosticLog()
        let client = SyncClient(
            serverClient: ActualServerClient(diagnosticLog: log),
            diagnosticLog: log
        )

        await client.resetSyncState()
        await client.cancelPendingSync()

        let report = await formattedReport(from: log.snapshot())
        #expect(report.contains("SYNC resync-triggered reason=manual-reset"))
    }

    @Test func recordsSafeConnectionAndSyncSnapshot() async {
        let log = DiagnosticLog()

        await log.recordServerConfiguration(
            transport: "HTTPS",
            fallbackConfigured: true
        )
        await log.recordCredentialAvailability(true)
        await log.recordNetworkRequest(
            method: "GET",
            path: "/info",
            statusCode: 200,
            error: nil,
            durationMilliseconds: 42
        )
        await log.recordSyncStarted()
        await log.recordSyncRequestMessageCount(3)
        await log.recordSyncResponseMessageCount(2)
        await log.recordSyncFinished(.success)

        let snapshot = await log.snapshot()
        #expect(snapshot.serverConfigured)
        #expect(snapshot.serverTransport == "https")
        #expect(snapshot.fallbackConfigured)
        #expect(snapshot.serverRoute == "primary")
        #expect(snapshot.connectionStatus == .online)
        #expect(snapshot.credentialPresent)
        #expect(snapshot.lastNetworkStatusCode == 200)
        #expect(snapshot.lastSyncResult == .success)
        #expect(snapshot.lastSyncRequestMessageCount == 3)
        #expect(snapshot.lastSyncResponseMessageCount == 2)
        #expect(snapshot.lastSyncDurationMilliseconds != nil)
    }

    @Test func mapsTransportFailuresToSafeCategories() {
        #expect(
            DiagnosticLog.NetworkError.from(.secureConnectionFailed)
                == .tls(code: URLError.Code.secureConnectionFailed.rawValue)
        )
        #expect(DiagnosticLog.NetworkError.from(.timedOut) == .timedOut)
        #expect(DiagnosticLog.NetworkError.from(.cannotFindHost) == .cannotFindHost)
        #expect(
            DiagnosticLog.NetworkError.from(
                .appTransportSecurityRequiresSecureConnection
            ) == .atsBlocked
        )
    }

    @Test func eventsFromAnOldDiagnosticSessionAreIgnored() async {
        let log = DiagnosticLog()
        let oldSession = await log.currentSessionID()

        await log.recordServerConfiguration(
            transport: "https",
            fallbackConfigured: false,
            sessionID: oldSession
        )
        await log.clear()

        await log.recordServerConfiguration(
            transport: "http",
            fallbackConfigured: true,
            sessionID: oldSession
        )
        await log.recordNetworkRequest(
            method: "GET",
            path: "/info",
            statusCode: 500,
            error: nil,
            durationMilliseconds: 1,
            sessionID: oldSession
        )

        let snapshot = await log.snapshot()
        #expect(snapshot.serverConfigured == false)
        #expect(snapshot.serverRoute == "none")
        #expect(snapshot.lastNetworkStatusCode == nil)
        #expect(snapshot.entries.isEmpty)
    }

    @Test func newSyncConfigurationClearsPreviousSyncSummary() async {
        let log = DiagnosticLog()

        await log.recordSyncStarted()
        await log.recordSyncRequestMessageCount(3)
        await log.recordSyncResponseMessageCount(2)
        await log.recordSyncFinished(.success)

        await log.recordSyncConfiguration()

        let snapshot = await log.snapshot()
        #expect(snapshot.lastSyncAttemptAt == nil)
        #expect(snapshot.lastSyncSuccessAt == nil)
        #expect(snapshot.lastSyncResult == nil)
        #expect(snapshot.lastSyncDurationMilliseconds == nil)
        #expect(snapshot.lastSyncRequestMessageCount == nil)
        #expect(snapshot.lastSyncResponseMessageCount == nil)
    }

    @Test func newSyncAttemptClearsPreviousAttemptMetrics() async {
        let log = DiagnosticLog()

        await log.recordSyncStarted()
        await log.recordSyncRequestMessageCount(3)
        await log.recordSyncResponseMessageCount(2)
        await log.recordSyncFinished(.success)

        await log.recordSyncStarted()

        let snapshot = await log.snapshot()
        #expect(snapshot.lastSyncResult == nil)
        #expect(snapshot.lastSyncDurationMilliseconds == nil)
        #expect(snapshot.lastSyncRequestMessageCount == nil)
        #expect(snapshot.lastSyncResponseMessageCount == nil)
        #expect(snapshot.lastSyncAttemptAt != nil)
    }

    @Test func expectedHttpStatusIsNotRecordedAsAnError() async throws {
        let log = DiagnosticLog()
        let client = ActualServerClient(
            session: StubTransport.session { _ in
                .init(status: 404, contentType: "application/json", body: Data())
            },
            diagnosticLog: log
        )

        try await client.configure(serverURL: "https://budget.example.com")
        let methods = try await client.fetchLoginMethods()

        #expect(methods.map(\.method) == ["password"])
        let snapshot = await log.snapshot()
        #expect(snapshot.lastNetworkStatusCode == 404)
        #expect(snapshot.lastNetworkError == nil)
    }

    @Test(.timeLimit(.minutes(5)))
    func networkCompletionFromPreviousSessionIsIgnored() async throws {
        let log = DiagnosticLog()
        let started = Gate()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let session = StubTransport.session { _ in
            started.open()
            release.wait()
            return .init(
                status: 500,
                contentType: "application/json",
                body: Data()
            )
        }
        let client = ActualServerClient(session: session, diagnosticLog: log)

        try await client.configure(serverURL: "https://budget.example.com")
        let requestTask = Task {
            try? await client.login(password: "password")
        }

        await started.wait()
        await log.clear()
        release.signal()
        _ = await requestTask.value

        let snapshot = await log.snapshot()
        #expect(snapshot.lastNetworkStatusCode == nil)
        #expect(snapshot.lastNetworkError == nil)
        #expect(snapshot.entries.filter { $0.message.hasPrefix("NETWORK ") }.isEmpty)
    }

    @Test(.timeLimit(.minutes(5)))
    func reconfigurationDuringRequestDoesNotExposePrivatePath() async throws {
        let log = DiagnosticLog()
        let started = Gate()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let client = ActualServerClient(
            session: StubTransport.session { _ in
                started.open()
                release.wait()
                return .init(status: 500, contentType: "application/json")
            },
            diagnosticLog: log
        )
        try await client.configure(serverURL: "https://budget.example.com/private-secret-route")
        let request = Task { try? await client.login(password: "password") }
        await started.wait()
        try await client.configure(serverURL: "https://another.example.com/new-route")
        release.signal()
        _ = await request.value

        let history = await formattedReport(from: log.snapshot())
        #expect(history.contains("path=/account/login"))
        #expect(!history.contains("private-secret-route"))
    }

    @Test func cancelledFallbackRequestDoesNotBecomeTransportFailure() async throws {
        let log = DiagnosticLog()
        let client = ActualServerClient(
            session: StubTransport.session { request in
                if request.url?.host == "primary.example.com" {
                    throw URLError(.cannotConnectToHost)
                }
                throw CancellationError()
            },
            diagnosticLog: log
        )

        try await client.configure(
            serverURL: "https://primary.example.com",
            fallbackServerURL: "https://fallback.example.com"
        )

        do {
            _ = try await client.login(password: "password")
            Issue.record("Expected cancellation")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Expected URLSession cancellation, got \(String(describing: error))")
        }

        let snapshot = await log.snapshot()
        let networkEntries = snapshot.entries.filter { $0.message.hasPrefix("NETWORK ") }
        #expect(networkEntries.count == 1)
        #expect(networkEntries[0].message.contains("cannot-connect"))
    }

    @Test func cancelledNetworkRequestDoesNotBecomeTransportFailure() async throws {
        let log = DiagnosticLog()
        let client = ActualServerClient(
            session: StubTransport.session { _ in
                throw CancellationError()
            },
            diagnosticLog: log
        )

        try await client.configure(serverURL: "https://budget.example.com")

        do {
            _ = try await client.login(password: "password")
            Issue.record("Expected cancellation")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Expected URLSession cancellation, got \(String(describing: error))")
        }

        #expect(await (log.snapshot()).entries.filter { $0.message.hasPrefix("NETWORK ") }.isEmpty)
    }

    @Test func successfulPasswordLoginRecordsCredentialAvailability() async throws {
        let log = DiagnosticLog()
        let client = ActualServerClient(
            session: StubTransport.session { _ in
                .init(
                    status: 200,
                    contentType: "application/json",
                    body: Data(#"{"status":"ok","data":{"token":"secret-token"}}"#.utf8)
                )
            },
            diagnosticLog: log
        )

        try await client.configure(serverURL: "https://budget.example.com")
        _ = try await client.login(password: "password")

        let snapshot = await log.snapshot()
        #expect(snapshot.credentialPresent)
        #expect(!formattedReport(from: snapshot).contains("secret-token"))
    }

    @Test func authProxyResponseIsRecordedWithoutResponseContent() async throws {
        let log = DiagnosticLog()
        let client = ActualServerClient(
            session: StubTransport.session { _ in
                .init(
                    status: 200,
                    contentType: "text/html; charset=utf-8",
                    body: Data("<html>proxy-secret</html>".utf8)
                )
            },
            diagnosticLog: log
        )

        try await client.configure(serverURL: "https://budget.example.com")
        do {
            _ = try await client.login(password: "password")
            Issue.record("Expected auth proxy response to fail login")
        } catch let error as ActualServerError {
            guard case .authProxyBlocked = error else {
                Issue.record("Expected authProxyBlocked, got \(error)")
                return
            }
        }

        let snapshot = await log.snapshot()
        #expect(snapshot.lastNetworkError == .authProxy)
        let report = formattedReport(from: snapshot)
        #expect(report.contains("error=auth-proxy"))
        #expect(!report.contains("proxy-secret"))
    }

    @Test func latestSuccessfulNetworkResultPreservesLastFailure() async {
        let log = DiagnosticLog()

        await log.recordNetworkRequest(
            method: "GET",
            path: "/info",
            statusCode: nil,
            error: .tls(code: -1200),
            durationMilliseconds: 10
        )
        await log.recordNetworkRequest(
            method: "GET",
            path: "/info",
            statusCode: 200,
            error: nil,
            durationMilliseconds: 20
        )

        let snapshot = await log.snapshot()
        #expect(snapshot.lastNetworkStatusCode == 200)
        #expect(snapshot.lastNetworkError == .tls(code: -1200))
    }

    @Test func cancelledSyncRecordsTerminalState() async {
        let log = DiagnosticLog()

        await log.recordSyncStarted()
        await log.recordSyncFinished(.cancelled)

        let snapshot = await log.snapshot()
        #expect(snapshot.lastSyncResult == .cancelled)
        #expect(snapshot.lastSyncDurationMilliseconds != nil)
        #expect(
            snapshot.entries.last?.message.hasPrefix(
                "SYNC finished result=cancelled"
            ) == true
        )
    }

    @Test func clearResetsSnapshotAndEventHistory() async {
        let log = DiagnosticLog()

        await log.recordServerConfiguration(
            transport: "HTTPS",
            fallbackConfigured: true
        )
        await log.recordCustomHeadersConfigured(true)
        await log.recordCredentialAvailability(true)
        await log.recordNetworkRequest(
            method: "GET",
            path: "/info",
            statusCode: 200,
            error: nil,
            durationMilliseconds: 10
        )
        await log.recordSyncStarted()
        await log.recordSyncFinished(.success)

        await log.clear()

        let snapshot = await log.snapshot()
        #expect(snapshot == .empty)
    }

    @MainActor
    @Test func diagnosticReportContainsEnvironmentAndPrivacySections() {
        let report = DiagnosticReportBuilder.make(
            snapshot: .empty,
            settings: .empty,
            environment: .empty,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(report.text.contains("Actuali Diagnostic Report"))
        #expect(report.text.contains("Generated: 2023-11-14T22:13:20.000Z"))
        #expect(report.text.contains("[Application]"))
        #expect(report.text.contains("[Device]"))
        #expect(report.text.contains("[Connection]"))
        #expect(report.text.contains("Custom headers configured: no"))
        #expect(report.text.contains("[Sync Status]"))
        #expect(report.text.contains("[Diagnostic Event History]"))
        #expect(report.text.contains("Scope: app session; events may include earlier budget or connection configurations."))
        #expect(report.text.contains("credentials"))
        #expect(!report.text.contains("Report ID:"))
        #expect(!report.text.contains("Background refresh:"))
        #expect(!report.text.contains("Locale:"))
        #expect(!report.text.contains("Preferred language:"))
        #expect(!report.text.contains("Time zone offset seconds:"))
        #expect(report.filename.hasPrefix("Actuali-Diagnostics-"))
        #expect(report.filename.hasSuffix(".txt"))
    }

    @MainActor
    @Test func diagnosticReportRendersEverySettingsField() {
        let settings = DiagnosticSettingsSnapshot(
            appearanceMode: "dark",
            startTab: "reports",
            defaultDashboardConfigured: true,
            currencyCode: "CAD",
            numberFormat: "dot-comma",
            useNarrowCurrencySymbol: true,
            budgetDisplayStyle: "compact",
            showCompactBudgetOverview: true,
            showBudgetedAmounts: false,
            showCompactSpentColumn: true,
            showGroupTotals: true,
            showBudgetCheckInStrip: false,
            hideZeroBudgetCategories: true,
            showHiddenCategories: true,
            showCategoryStatusDots: false,
            customCategoryStatusColorCount: 3,
            showBudgetProgressBars: true,
            showInverseBudgetProgressBars: true,
            hiddenBudgetProgressCategoryCount: 2,
            spentCategoryExclusionCount: 2,
            showOverspentBadge: false,
            hideIncomeGroup: true,
            goalTemplatesEnabled: true,
            goalTemplatesUIEnabled: true,
            transactionDisplayMode: "groupedByDate",
            transactionStatusFilter: "cleared",
            showTransactionStatusFilters: false,
            uncategorizedTapAction: "transactionEditor",
            conventionalAmountEntry: true,
            defaultAccountConfigured: true,
            recordPayeeLocations: true,
            payeeLocationWritesSupported: true,
            hideBalances: true,
            shakeToHideBalances: true,
            hideDecimalPlaces: true,
            hideClosedAccounts: true,
            transactionNotificationsEnabled: true,
            creditCardDueNotificationsEnabled: true,
            cardAccountMappingCount: 2,
            creditCardConfigurationCount: 3,
            loanConfigurationCount: 4,
            depositConfigurationCount: 5,
            categoryFundingConfigured: true,
            categoryFundingEnabled: true,
            categoryFundingSource: "category"
        )
        let report = DiagnosticReportBuilder.make(
            snapshot: .empty,
            settings: settings,
            environment: .empty,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        for expected in [
            "Appearance: dark",
            "Start page: reports",
            "Default dashboard configured: yes",
            "Currency: CAD",
            "Number format: dot-comma",
            "Narrow currency symbol: yes",
            "Budget view style: compact",
            "Show compact budget overview: yes",
            "Show spent: yes",
            "Budgeted amounts: no",
            "Group totals: yes",
            "Budget status filters: no",
            "Hide spent categories: yes",
            "Show hidden categories: yes",
            "Category status dots: no",
            "Custom category status colors: 3",
            "Budget progress bars: yes",
            "Inverse progress bars: yes",
            "Categories with hidden progress bars: 2",
            "Categories excluded from spent: 2",
            "Overspent badge: no",
            "Hide income group: yes",
            "Budget goal templates: yes",
            "Automations editor: yes",
            "Transaction display: groupedByDate",
            "Transaction status filter: cleared",
            "Transaction status filters: no",
            "Uncategorized action: transactionEditor",
            "Conventional amount entry: yes",
            "Default account configured: yes",
            "Record payee locations: yes",
            "Payee location writes supported: yes",
            "Hide balances: yes",
            "Shake to toggle balances: yes",
            "Hide decimal places: yes",
            "Hide closed accounts: yes",
            "New transaction alerts: yes",
            "Credit card due reminders: yes",
            "Card & account mappings: 2",
            "Credit card configurations: 3",
            "Loan configurations: 4",
            "Deposit configurations: 5",
            "Category funding configured: yes",
            "Category funding enabled: yes",
            "Category funding source: category",
        ] {
            #expect(report.text.contains(expected))
        }
    }
}
