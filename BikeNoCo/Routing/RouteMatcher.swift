import Foundation
import CoreLocation

/// Decides whether a freely recorded ride should auto-link to a saved route.
enum RouteMatcher {
    private static let proximityMeters = 30.0
    private static let minTrackCoverage = 0.80
    private static let maxDistanceRatioDelta = 0.10

    static func shouldLink(
        track: [CLLocationCoordinate2D],
        trackDistanceMeters: Double,
        routeCoordinates: [CLLocationCoordinate2D],
        routeDistanceMeters: Double
    ) -> Bool {
        guard track.count >= 2, routeCoordinates.count >= 2 else { return false }
        guard routeDistanceMeters > 0, trackDistanceMeters > 0 else { return false }

        let distanceRatio = abs(trackDistanceMeters - routeDistanceMeters) / routeDistanceMeters
        guard distanceRatio <= maxDistanceRatioDelta else { return false }

        let coverage = PolylineProximity.lengthShareWithin(
            sample: track,
            of: routeCoordinates,
            thresholdMeters: proximityMeters
        )
        return coverage >= minTrackCoverage
    }

    /// Best matching saved-route geometry among candidates, if any qualify.
    static func bestMatch(
        track: [CLLocationCoordinate2D],
        trackDistanceMeters: Double,
        candidates: [(id: UUID, coordinates: [CLLocationCoordinate2D], distanceMeters: Double)]
    ) -> UUID? {
        var bestID: UUID?
        var bestCoverage = 0.0

        for candidate in candidates {
            guard shouldLink(
                track: track,
                trackDistanceMeters: trackDistanceMeters,
                routeCoordinates: candidate.coordinates,
                routeDistanceMeters: candidate.distanceMeters
            ) else { continue }

            let coverage = PolylineProximity.lengthShareWithin(
                sample: track,
                of: candidate.coordinates,
                thresholdMeters: proximityMeters
            )
            if coverage > bestCoverage {
                bestCoverage = coverage
                bestID = candidate.id
            }
        }
        return bestID
    }
}
