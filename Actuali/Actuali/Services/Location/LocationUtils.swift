import Foundation

/// Pure location math/formatting, mirroring upstream
/// `loot-core/src/shared/location-utils.ts` and `shared/constants.ts`.
enum LocationUtils {
    /// Upstream DEFAULT_MAX_DISTANCE_METERS: nearby-payee radius and the
    /// dedupe radius for recording new locations.
    static let defaultMaxDistanceMeters: Double = 500

    /// Haversine distance in meters (Earth radius 6371e3, as upstream).
    static func calculateDistanceMeters(
        lat1: Double, lon1: Double, lat2: Double, lon2: Double
    ) -> Double {
        let r = 6371e3
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return r * c
    }

    /// Upstream format: "328ft | 100m".
    static func formatDistance(meters: Double) -> String {
        let feet = Int((meters * 3.28084).rounded())
        return "\(feet)ft | \(Int(meters.rounded()))m"
    }

    /// Upstream coordinate validation (createPayeeLocation / getNearbyPayees).
    static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }
}
