import Foundation
import Synchronization
import Testing
@testable import Actuali

struct StubTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func stalledRequestDoesNotBlockAnotherSession() async throws {
        let started = Gate()
        let release = DispatchSemaphore(value: 0)
        let completed = Mutex(false)
        defer { release.signal() }
        let stalledSession = StubTransport.session { _ in
            started.open()
            release.wait()
            completed.withLock { $0 = true }
            return .init()
        }
        let request = URLRequest(url: URL(string: "https://budget.example.com/info")!)
        let stalled = Task { try await stalledSession.data(for: request) }
        await started.wait()

        let respondingSession = StubTransport.session { _ in .init(body: Data("ok".utf8)) }
        let (body, _) = try await respondingSession.data(for: request)
        #expect(body == Data("ok".utf8))
        #expect(!completed.withLock { $0 }, "one stalled session blocked an unrelated request")

        release.signal()
        _ = try await stalled.value
    }
}
