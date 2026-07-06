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
    func authorizationStatus() -> LocationAuthStatus {
        Self.map(CLLocationManager().authorizationStatus)
    }

    func requestPermission() async -> LocationAuthStatus {
        let current = CLLocationManager().authorizationStatus
        guard current == .notDetermined else { return Self.map(current) }
        // requestWhenInUseAuthorization delegate dance: hold a manager +
        // delegate until the user answers the prompt.
        return await withCheckedContinuation { continuation in
            let delegate = PermissionDelegate { status in
                continuation.resume(returning: Self.map(status))
            }
            delegate.manager.delegate = delegate
            delegate.manager.requestWhenInUseAuthorization()
        }
    }

    func fetchPosition() async throws -> Coordinates {
        // CLLocationUpdate.liveUpdates (iOS 17+) gives a simple async
        // one-shot without delegate plumbing.
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
