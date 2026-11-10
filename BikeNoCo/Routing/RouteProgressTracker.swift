import Foundation
import CoreLocation

struct RouteProgress: Equatable {
    /// Meters from the route origin to the matched point.
    var distanceAlongRoute: Double
    /// Perpendicular distance from the fix to the matched point (meters).
    var distanceFromRoute: Double
    /// Meters remaining to the destination along the route.
    var remainingDistance: Double
    /// Index of the most recently passed (or current) maneuver.
    var currentManeuverIndex: Int
    /// Upcoming maneuver, if any.
    var nextManeuver: Maneuver?
    /// Meters along the route to the next maneuver (0 if none / arrived).
    var distanceToNextManeuver: Double
    /// Whether this update produced a new polyline match.
    var didMatch: Bool
}

/// Matches GPS fixes to a planned-route polyline using a forward search window.
struct RouteProgressTracker {
    private static let searchAheadMeters: Double = 300
    private static let maxBackwardMeters: Double = 30
    private static let maxMatchAccuracyMeters: Double = 25

    private let coordinates: [CLLocationCoordinate2D]
    private let locals: [LocalPoint]
    private let cumulative: [Double]
    private let routeLength: Double
    private let maneuvers: [Maneuver]
    private let projection: LocalProjection

    private var lastDistanceAlong: Double = 0
    private var lastSegmentIndex: Int = 0
    private var lastProgress: RouteProgress

    init(coordinates: [CLLocationCoordinate2D], maneuvers: [Maneuver]) {
        precondition(!coordinates.isEmpty)
        self.coordinates = coordinates
        self.maneuvers = maneuvers

        let origin = coordinates[0]
        let projection = LocalProjection(
            originLatitude: origin.latitude,
            originLongitude: origin.longitude
        )
        self.projection = projection

        let locals = coordinates.map { projection.toLocal($0) }
        self.locals = locals

        var cumulative: [Double] = [0]
        var total = 0.0
        if locals.count > 1 {
            for i in 1..<locals.count {
                total += locals[i - 1].distance(to: locals[i])
                cumulative.append(total)
            }
        }
        self.cumulative = cumulative
        self.routeLength = total

        self.lastProgress = RouteProgress(
            distanceAlongRoute: 0,
            distanceFromRoute: 0,
            remainingDistance: total,
            currentManeuverIndex: 0,
            nextManeuver: Self.nextManeuver(after: 0, in: maneuvers, distanceAlong: 0),
            distanceToNextManeuver: Self.distanceToNext(after: 0, in: maneuvers, distanceAlong: 0),
            didMatch: false
        )
    }

    var progress: RouteProgress { lastProgress }
    var lengthMeters: Double { routeLength }

    mutating func update(location: CLLocation) -> RouteProgress {
        // Low-accuracy fixes are still recorded by RideRecorder; skip matching.
        if location.horizontalAccuracy < 0 || location.horizontalAccuracy > Self.maxMatchAccuracyMeters {
            var skipped = lastProgress
            skipped.didMatch = false
            lastProgress = skipped
            return skipped
        }

        guard locals.count >= 2 else {
            var trivial = lastProgress
            trivial.distanceFromRoute = projection.toLocal(location.coordinate)
                .distance(to: locals[0])
            trivial.didMatch = true
            lastProgress = trivial
            return trivial
        }

        let point = projection.toLocal(location.coordinate)
        let windowStart = max(0, lastDistanceAlong - Self.maxBackwardMeters)
        let windowEnd = min(routeLength, lastDistanceAlong + Self.searchAheadMeters)

        let startSegment = max(0, segmentIndex(containing: windowStart) - 1)
        let endSegment = min(locals.count - 2, segmentIndex(containing: windowEnd) + 1)

        var bestDistance = Double.greatestFiniteMagnitude
        var bestAlong = lastDistanceAlong
        var bestSegment = lastSegmentIndex

        for i in startSegment...endSegment {
            let a = locals[i]
            let b = locals[i + 1]
            let projected = point.projected(ontoSegmentFrom: a, to: b)
            let along = cumulative[i] + projected.t * (cumulative[i + 1] - cumulative[i])
            if along < windowStart - 1e-6 || along > windowEnd + 1e-6 {
                continue
            }
            if projected.distance < bestDistance {
                bestDistance = projected.distance
                bestAlong = along
                bestSegment = i
            }
        }

        // If nothing in-window (degenerate), keep prior match but report distance.
        if bestDistance == .greatestFiniteMagnitude {
            var unmatched = lastProgress
            unmatched.distanceFromRoute = distanceToClosestInWindow(point: point, start: startSegment, end: endSegment)
            unmatched.didMatch = false
            lastProgress = unmatched
            return unmatched
        }

        lastDistanceAlong = bestAlong
        lastSegmentIndex = bestSegment

        let currentIndex = Self.currentManeuverIndex(in: maneuvers, distanceAlong: bestAlong)
        let next = Self.nextManeuver(after: currentIndex, in: maneuvers, distanceAlong: bestAlong)
        let progress = RouteProgress(
            distanceAlongRoute: bestAlong,
            distanceFromRoute: bestDistance,
            remainingDistance: max(0, routeLength - bestAlong),
            currentManeuverIndex: currentIndex,
            nextManeuver: next,
            distanceToNextManeuver: Self.distanceToNext(after: currentIndex, in: maneuvers, distanceAlong: bestAlong),
            didMatch: true
        )
        lastProgress = progress
        return progress
    }

    // MARK: - Helpers

    private func segmentIndex(containing distance: Double) -> Int {
        guard cumulative.count > 1 else { return 0 }
        var lo = 0
        var hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] < distance {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return max(0, min(locals.count - 2, lo - 1))
    }

    private func distanceToClosestInWindow(point: LocalPoint, start: Int, end: Int) -> Double {
        var best = Double.greatestFiniteMagnitude
        for i in start...end {
            let d = point.projected(ontoSegmentFrom: locals[i], to: locals[i + 1]).distance
            best = min(best, d)
        }
        return best
    }

    private static func currentManeuverIndex(in maneuvers: [Maneuver], distanceAlong: Double) -> Int {
        guard !maneuvers.isEmpty else { return 0 }
        var index = 0
        for i in maneuvers.indices {
            if maneuvers[i].distanceAlongRoute <= distanceAlong + 1e-6 {
                index = i
            } else {
                break
            }
        }
        return index
    }

    private static func nextManeuver(
        after currentIndex: Int,
        in maneuvers: [Maneuver],
        distanceAlong: Double
    ) -> Maneuver? {
        guard !maneuvers.isEmpty else { return nil }
        let start = min(currentIndex + 1, maneuvers.count)
        for i in start..<maneuvers.count {
            if maneuvers[i].distanceAlongRoute > distanceAlong + 1e-6 {
                return maneuvers[i]
            }
        }
        return maneuvers.last
    }

    private static func distanceToNext(
        after currentIndex: Int,
        in maneuvers: [Maneuver],
        distanceAlong: Double
    ) -> Double {
        guard let next = nextManeuver(after: currentIndex, in: maneuvers, distanceAlong: distanceAlong) else {
            return 0
        }
        return max(0, next.distanceAlongRoute - distanceAlong)
    }
}
