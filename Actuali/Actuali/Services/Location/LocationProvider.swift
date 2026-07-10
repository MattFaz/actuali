import CoreLocation
import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "Location")

struct Coordinates: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

enum LocationAuthStatus: Sendable {
    case notDetermined
    case granted
    case denied
}

enum LocationError: Error {
    case permissionDenied
    case unavailable
}

/// Abstraction over CoreLocation so tests can inject a fake.
protocol PositionSource: Sendable {
    func requestPermission() async -> LocationAuthStatus
    func authorizationStatus() -> LocationAuthStatus
    func fetchPosition() async throws -> Coordinates
}

/// Async facade over CoreLocation with a 60 s position cache (matching the
/// upstream web client's LocationService.CACHE_DURATION).
actor LocationProvider {
    private let source: PositionSource
    private var cached: (position: Coordinates, at: ContinuousClock.Instant)?
    private let cacheDuration: Duration = .seconds(60)
    private let clock = ContinuousClock()

    init(source: PositionSource = CoreLocationSource()) {
        self.source = source
    }

    func authorizationStatus() -> LocationAuthStatus {
        source.authorizationStatus()
    }

    /// Prompts iOS for when-in-use permission if not yet determined.
    func requestPermission() async -> LocationAuthStatus {
        await source.requestPermission()
    }

    /// Current position, served from cache when fresh. Throws when
    /// permission is denied or no fix is available.
    func currentPosition() async throws -> Coordinates {
        guard source.authorizationStatus() == .granted else {
            throw LocationError.permissionDenied
        }
        if let cached, clock.now - cached.at < cacheDuration {
            return cached.position
        }
        let position = try await source.fetchPosition()
        cached = (position, clock.now)
        return position
    }
}

/// Real CoreLocation-backed source. One-shot fixes only — no continuous
/// monitoring, no background use.
final class CoreLocationSource: NSObject, PositionSource, @unchecked Sendable {
    /// Single delegate-less manager reused for status reads. Creating and
    /// reading a CLLocationManager off-main is fine as long as no delegate is
    /// ever attached (delegate callbacks are what need a run loop).
    private let statusManager = CLLocationManager()

    func authorizationStatus() -> LocationAuthStatus {
        Self.map(statusManager.authorizationStatus)
    }

    func requestPermission() async -> LocationAuthStatus {
        guard statusManager.authorizationStatus == .notDetermined else {
            return Self.map(statusManager.authorizationStatus)
        }
        return Self.map(await Self.promptForPermission())
    }

    /// requestWhenInUseAuthorization delegate dance: hold a manager + delegate
    /// until the user answers the prompt. Runs on the main actor because
    /// CoreLocation delivers delegate callbacks via the run loop of the thread
    /// that created the manager — cooperative-pool threads have none, so the
    /// callback would never fire and the continuation would never resume.
    @MainActor
    private static func promptForPermission() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            let delegate = PermissionDelegate { status in
                continuation.resume(returning: status)
            }
            delegate.manager.delegate = delegate
            delegate.manager.requestWhenInUseAuthorization()
        }
    }

    func fetchPosition() async throws -> Coordinates {
        // CLLocationUpdate.liveUpdates (iOS 17+) gives a simple async
        // one-shot without delegate plumbing. Raced against a 15 s timeout
        // (matching the upstream web client) so diagnostic nil-location
        // updates can't keep the location hardware running indefinitely;
        // cancelling the group ends the liveUpdates iteration.
        try await withThrowingTaskGroup(of: Coordinates.self) { group in
            group.addTask {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let location = update.location {
                        return Coordinates(
                            latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude)
                    }
                    if update.authorizationDenied {
                        logger.info("Location fetch aborted: authorization denied")
                        throw LocationError.permissionDenied
                    }
                }
                throw LocationError.unavailable
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                logger.info("Location fetch timed out after 15 s")
                throw LocationError.unavailable
            }
            defer { group.cancelAll() }
            guard let position = try await group.next() else {
                throw LocationError.unavailable
            }
            return position
        }
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationAuthStatus {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Keeps itself and its manager alive until the authorization callback.
    private final class PermissionDelegate: NSObject, CLLocationManagerDelegate {
        let manager = CLLocationManager()
        private var completion: ((CLAuthorizationStatus) -> Void)?
        private var retained: PermissionDelegate?

        init(completion: @escaping (CLAuthorizationStatus) -> Void) {
            self.completion = completion
            super.init()
            retained = self
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard manager.authorizationStatus != .notDetermined else { return }
            completion?(manager.authorizationStatus)
            completion = nil
            retained = nil
        }
    }
}
