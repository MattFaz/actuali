import Foundation

struct DiagnosticLogEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let date: Date
    let message: String

    init(date: Date = Date(), message: String) {
        self.id = UUID()
        self.date = date
        self.message = message
    }
}

struct DiagnosticLogSnapshot: Sendable, Equatable {
    let entries: [DiagnosticLogEntry]
    let serverConfigured: Bool
    let serverTransport: String
    let fallbackConfigured: Bool
    let serverRoute: String
    let connectionStatus: DiagnosticLog.ConnectionStatus
    let credentialPresent: Bool
    let customHeadersConfigured: Bool
    let lastNetworkStatusCode: Int?
    let lastNetworkError: DiagnosticLog.NetworkError?
    let lastSyncAttemptAt: Date?
    let lastSyncSuccessAt: Date?
    let lastSyncResult: DiagnosticLog.SyncResult?
    let lastSyncDurationMilliseconds: Int?
    let lastSyncRequestMessageCount: Int?
    let lastSyncResponseMessageCount: Int?

    static let empty = DiagnosticLogSnapshot(
        entries: [],
        serverConfigured: false,
        serverTransport: "not configured",
        fallbackConfigured: false,
        serverRoute: "none",
        connectionStatus: .unknown,
        credentialPresent: false,
        customHeadersConfigured: false,
        lastNetworkStatusCode: nil,
        lastNetworkError: nil,
        lastSyncAttemptAt: nil,
        lastSyncSuccessAt: nil,
        lastSyncResult: nil,
        lastSyncDurationMilliseconds: nil,
        lastSyncRequestMessageCount: nil,
        lastSyncResponseMessageCount: nil
    )
}

actor DiagnosticLog {
    typealias SessionID = UUID

    enum ConnectionStatus: String, Sendable, Equatable {
        case unknown
        case online
        case offline
    }

    enum NetworkError: Sendable, Equatable {
        case timedOut
        case notConnectedToInternet
        case dnsLookupFailed
        case cannotFindHost
        case cannotConnectToHost
        case authProxy
        case http(statusCode: Int)
        case tls(code: Int)
        case atsBlocked
        case transport(code: Int)

        static func from(_ code: URLError.Code) -> Self {
            switch code {
            case .timedOut:
                .timedOut
            case .notConnectedToInternet:
                .notConnectedToInternet
            case .dnsLookupFailed:
                .dnsLookupFailed
            case .cannotFindHost:
                .cannotFindHost
            case .cannotConnectToHost:
                .cannotConnectToHost
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot:
                .tls(code: code.rawValue)
            case .appTransportSecurityRequiresSecureConnection:
                .atsBlocked
            default:
                .transport(code: code.rawValue)
            }
        }

        var diagnosticDescription: String {
            switch self {
            case .timedOut:
                "timeout"
            case .notConnectedToInternet:
                "no-internet"
            case .dnsLookupFailed:
                "dns-lookup-failed"
            case .cannotFindHost:
                "host-not-found"
            case .cannotConnectToHost:
                "cannot-connect"
            case .authProxy:
                "auth-proxy"
            case .http(let statusCode):
                "http(\(statusCode))"
            case .tls(let code):
                "tls(\(code))"
            case .atsBlocked:
                "ats-blocked"
            case .transport(let code):
                "transport(\(code))"
            }
        }
    }

    enum SyncResult: String, Sendable, Equatable {
        case success
        case offline
        case cancelled
        case failed
    }

    enum ResyncReason: String, Sendable {
        case merkleMismatch = "merkle-mismatch"
        case manualReset = "manual-reset"
    }

    static let shared = DiagnosticLog()

    private let capacity: Int
    private var sessionID = SessionID()
    private var entries: [DiagnosticLogEntry] = []
    private var serverConfigured = false
    private var serverTransport = "not configured"
    private var fallbackConfigured = false
    private var serverRoute = "none"
    private var connectionStatus: ConnectionStatus = .unknown
    private var credentialPresent = false
    private var customHeadersConfigured = false
    private var lastNetworkStatusCode: Int?
    private var lastNetworkError: NetworkError?
    private var lastSyncAttemptAt: Date?
    private var lastSyncSuccessAt: Date?
    private var lastSyncResult: SyncResult?
    private var lastSyncDurationMilliseconds: Int?
    private var lastSyncRequestMessageCount: Int?
    private var lastSyncResponseMessageCount: Int?
    private var syncStartedAt: Date?

    init(capacity: Int = 300) {
        self.capacity = max(1, capacity)
    }

    func currentSessionID() -> SessionID {
        sessionID
    }

    func clear() {
        sessionID = SessionID()
        entries.removeAll(keepingCapacity: true)
        serverConfigured = false
        serverTransport = "not configured"
        fallbackConfigured = false
        serverRoute = "none"
        connectionStatus = .unknown
        credentialPresent = false
        customHeadersConfigured = false
        lastNetworkStatusCode = nil
        lastNetworkError = nil
        lastSyncAttemptAt = nil
        lastSyncSuccessAt = nil
        lastSyncResult = nil
        lastSyncDurationMilliseconds = nil
        lastSyncRequestMessageCount = nil
        lastSyncResponseMessageCount = nil
        syncStartedAt = nil
    }

    func snapshot() -> DiagnosticLogSnapshot {
        DiagnosticLogSnapshot(
            entries: entries,
            serverConfigured: serverConfigured,
            serverTransport: serverTransport,
            fallbackConfigured: fallbackConfigured,
            serverRoute: serverRoute,
            connectionStatus: connectionStatus,
            credentialPresent: credentialPresent,
            customHeadersConfigured: customHeadersConfigured,
            lastNetworkStatusCode: lastNetworkStatusCode,
            lastNetworkError: lastNetworkError,
            lastSyncAttemptAt: lastSyncAttemptAt,
            lastSyncSuccessAt: lastSyncSuccessAt,
            lastSyncResult: lastSyncResult,
            lastSyncDurationMilliseconds: lastSyncDurationMilliseconds,
            lastSyncRequestMessageCount: lastSyncRequestMessageCount,
            lastSyncResponseMessageCount: lastSyncResponseMessageCount
        )
    }

    func recordServerConfiguration(transport: String, fallbackConfigured: Bool, sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        serverConfigured = true
        serverTransport = transport.lowercased()
        self.fallbackConfigured = fallbackConfigured
        serverRoute = "primary"
        connectionStatus = .unknown
        lastNetworkStatusCode = nil
        lastNetworkError = nil
        append(
            "CONFIG server transport=" + serverTransport
                + " fallback=" + (fallbackConfigured ? "yes" : "no")
        )
    }

    func recordServerRoute(_ route: String, sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        guard route == "primary" || route == "fallback" else { return }
        serverRoute = route
        append("ROUTE " + route)
    }

    func recordCredentialAvailability(_ available: Bool, sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        credentialPresent = available
    }

    func recordCustomHeadersConfigured(_ configured: Bool, sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        customHeadersConfigured = configured
    }

    func recordNetworkRequest(
        method: String,
        path: String,
        statusCode: Int?,
        error: NetworkError?,
        expectedStatusCodes: Set<Int> = [200],
        durationMilliseconds: Int,
        sessionID: SessionID? = nil
    ) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        lastNetworkStatusCode = statusCode
        connectionStatus = statusCode == nil && error != nil ? .offline : .online

        let resolvedError: NetworkError? = if let error {
            error
        } else if let statusCode, !expectedStatusCodes.contains(statusCode) {
            .http(statusCode: statusCode)
        } else {
            nil
        }
        if let resolvedError {
            lastNetworkError = resolvedError
        }

        let status = statusCode.map(String.init) ?? "none"
        let safeError = resolvedError?.diagnosticDescription ?? "none"

        append(
            "NETWORK method=\(method) path=\(path) status=\(status) error=\(safeError) duration=\(max(0, durationMilliseconds))ms"
        )
    }

    func recordSyncConfiguration(sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        lastSyncAttemptAt = nil
        lastSyncSuccessAt = nil
        lastSyncResult = nil
        lastSyncDurationMilliseconds = nil
        lastSyncRequestMessageCount = nil
        lastSyncResponseMessageCount = nil
        syncStartedAt = nil
        append("CONFIG sync-budget")
    }

    func recordSyncStarted(sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        let now = Date()
        lastSyncAttemptAt = now
        lastSyncResult = nil
        lastSyncDurationMilliseconds = nil
        lastSyncRequestMessageCount = nil
        lastSyncResponseMessageCount = nil
        syncStartedAt = now
        append("SYNC started")
    }

    func recordSyncFinished(_ result: SyncResult, sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        let finishedAt = Date()
        lastSyncResult = result
        if let syncStartedAt {
            lastSyncDurationMilliseconds = max(
                0,
                Int((finishedAt.timeIntervalSince(syncStartedAt) * 1000).rounded())
            )
        }
        if result == .success {
            lastSyncSuccessAt = finishedAt
        }
        syncStartedAt = nil
        append(
            "SYNC finished result=\(result.rawValue) duration=\(lastSyncDurationMilliseconds ?? 0)ms"
        )
    }

    func recordSyncRequestMessageCount(_ count: Int, sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        let count = max(0, count)
        lastSyncRequestMessageCount = count
        append("SYNC request-messages=\(count)")
    }

    func recordSyncResponseMessageCount(_ count: Int, sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        let count = max(0, count)
        lastSyncResponseMessageCount = count
        append("SYNC response-messages=\(count)")
    }

    func recordMerkleMismatch(sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        append("SYNC merkle-mismatch")
    }

    func recordResyncTriggered(reason: ResyncReason, sessionID: SessionID? = nil) {
        guard sessionID == nil || sessionID == self.sessionID else { return }
        append("SYNC resync-triggered reason=\(reason.rawValue)")
    }

    private func append(_ message: String) {
        entries.append(DiagnosticLogEntry(message: message))
        // ponytail: shifting at most 300 entries is cheap; use a deque if the
        // retained history grows enough for this to matter.
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}
