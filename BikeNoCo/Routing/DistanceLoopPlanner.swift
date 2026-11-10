import Foundation
import CoreLocation

/// Placeholder until elevation data exists — do not use for filtering or scoring yet.
enum ElevationBand: String, Equatable, Sendable {
    case easy
    case moderate
    case challenging
    case any
}

struct LoopSearchConstraints: Equatable, Sendable {
    var origin: CLLocationCoordinate2D
    var targetDistanceMeters: Double
    /// Relative tolerance around the target (default ±10%).
    var tolerance: Double = 0.10
    var maxLTS: Int? = nil
    var preferTrails: Bool = false
    /// When set with preferTrails / strict mode, reject candidates below this trail share.
    var minTrailShare: Double? = nil
    /// Unused until elevation data exists.
    var elevationPreference: ElevationBand? = nil

    static func == (lhs: LoopSearchConstraints, rhs: LoopSearchConstraints) -> Bool {
        abs(lhs.origin.latitude - rhs.origin.latitude) < 1e-8
            && abs(lhs.origin.longitude - rhs.origin.longitude) < 1e-8
            && abs(lhs.targetDistanceMeters - rhs.targetDistanceMeters) < 0.01
            && abs(lhs.tolerance - rhs.tolerance) < 1e-6
            && lhs.maxLTS == rhs.maxLTS
            && lhs.preferTrails == rhs.preferTrails
            && optionalClose(lhs.minTrailShare, rhs.minTrailShare)
            && lhs.elevationPreference == rhs.elevationPreference
    }

    private static func optionalClose(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a - b) < 1e-6
        default: return false
        }
    }
}

struct LoopCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let route: PlannedRoute
    let score: Double
    /// Compass bearing (degrees clockwise from north) used to seed this candidate.
    let bearingDegrees: Double
    let trailShare: Double
    let overlapShare: Double
    let lowStressShare: Double
    let distanceMeters: Double

    static func == (lhs: LoopCandidate, rhs: LoopCandidate) -> Bool {
        lhs.id == rhs.id
    }
}

struct LoopSearchResult: Equatable, Sendable {
    let candidates: [LoopCandidate]
    let elapsedSeconds: Double
    /// Seconds until the first in-tolerance diverse candidate was published. Nil if none.
    let timeToFirstResultSeconds: Double?
}

/// Waypoint-ring search that builds 3–5 distinct loops near a target distance.
enum DistanceLoopPlanner {
    private static let bearingsCount = 8
    private static let maxIterationsPerBearing = 2
    private static let radiusDivisor = 5.5
    private static let waypointSpreadDegrees = 50.0
    private static let diversityOverlapThreshold = 0.50
    private static let maxCandidates = 5

    /// - Parameter onShortlistChanged: Invoked on the caller's thread (often a background
    ///   queue) each time the ranked+diverse shortlist changes. The final result still
    ///   returns the completed shortlist.
    static func search(
        constraints: LoopSearchConstraints,
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default,
        randomOffsetDegrees: Double? = nil,
        isCancelled: () -> Bool = { false },
        onShortlistChanged: (@Sendable ([LoopCandidate]) -> Void)? = nil
    ) -> LoopSearchResult {
        let started = CFAbsoluteTimeGetCurrent()
        var workingProfile = profile
        if let maxLTS = constraints.maxLTS {
            workingProfile.maxLTS = maxLTS
        }
        if constraints.preferTrails {
            workingProfile.preferTrails = true
        }
        // Immutable copy for concurrent bearings (avoid capturing the mutable var).
        let searchProfile = workingProfile

        let offset = randomOffsetDegrees ?? Double.random(in: 0..<45)
        let projection = LocalProjection(
            originLatitude: constraints.origin.latitude,
            originLongitude: constraints.origin.longitude
        )
        let originLocal = projection.toLocal(constraints.origin)
        // Build the snap index once — rebuilding it per A* call dominated search time.
        let routingIndex = RoutingIndex(graph: graph)

        // Search bearings in parallel; A* is the hot path and benefits from multi-core.
        let lock = NSLock()
        var raw: [LoopCandidate] = []
        var timeToFirst: Double?

        DispatchQueue.concurrentPerform(iterations: bearingsCount) { bearingIndex in
            if isCancelled() { return }
            let bearing = Double(bearingIndex) * 45.0 + offset
            guard let candidate = searchBearing(
                bearingDegrees: bearing,
                constraints: constraints,
                graph: graph,
                profile: searchProfile,
                originLocal: originLocal,
                projection: projection,
                routingIndex: routingIndex,
                isCancelled: isCancelled
            ) else { return }

            let shortlist: [LoopCandidate]
            lock.lock()
            raw.append(candidate)
            let filtered = applyHardFilters(raw, constraints: constraints)
            let ranked = filtered.sorted { $0.score > $1.score }
            shortlist = Array(applyDiversity(ranked).prefix(maxCandidates))
            if timeToFirst == nil, !shortlist.isEmpty {
                timeToFirst = CFAbsoluteTimeGetCurrent() - started
            }
            lock.unlock()

            onShortlistChanged?(shortlist)
        }

        lock.lock()
        let filtered = applyHardFilters(raw, constraints: constraints)
        let ranked = filtered.sorted { $0.score > $1.score }
        let top = Array(applyDiversity(ranked).prefix(maxCandidates))
        let first = timeToFirst
        lock.unlock()

        return LoopSearchResult(
            candidates: top,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - started,
            timeToFirstResultSeconds: first
        )
    }

    // MARK: - Per-bearing search

    private static func searchBearing(
        bearingDegrees: Double,
        constraints: LoopSearchConstraints,
        graph: BikeNetworkGraph,
        profile: RoutingProfile,
        originLocal: LocalPoint,
        projection: LocalProjection,
        routingIndex: RoutingIndex,
        isCancelled: () -> Bool
    ) -> LoopCandidate? {
        let target = constraints.targetDistanceMeters
        var radius = target / radiusDivisor

        for _ in 0..<maxIterationsPerBearing {
            if isCancelled() { return nil }

            let w1Bearing = bearingDegrees - waypointSpreadDegrees
            let w2Bearing = bearingDegrees + waypointSpreadDegrees
            let w1 = coordinate(
                from: originLocal,
                bearingDegrees: w1Bearing,
                distanceMeters: radius,
                projection: projection
            )
            let w2 = coordinate(
                from: originLocal,
                bearingDegrees: w2Bearing,
                distanceMeters: radius,
                projection: projection
            )

            let waypoints = [constraints.origin, w1, w2, constraints.origin]
            let routed = RouteFinder.routeThrough(
                waypoints: waypoints,
                graph: graph,
                profile: profile,
                cumulativeReusePenalties: true,
                tripShape: .loop,
                routingIndex: routingIndex
            )

            switch routed {
            case .failure:
                // Unsnappable waypoint or disconnected — skip this bearing.
                return nil
            case .success(let route):
                let actual = route.totalDistanceMeters
                guard actual > 1 else { return nil }

                let relativeError = abs(actual - target) / target
                if relativeError <= constraints.tolerance {
                    let fit = distanceFit(actual: actual, target: target, tolerance: constraints.tolerance)
                    let trail = route.trailShare
                    let overlap = route.overlapShare ?? 0
                    let score = scoreCandidate(
                        lowStress: route.lowStressShare,
                        trailShare: trail,
                        overlapShare: overlap,
                        distanceFit: fit,
                        preferTrails: constraints.preferTrails
                    )
                    return LoopCandidate(
                        id: UUID(),
                        name: name(for: route, bearingDegrees: bearingDegrees),
                        route: route,
                        score: score,
                        bearingDegrees: bearingDegrees,
                        trailShare: trail,
                        overlapShare: overlap,
                        lowStressShare: route.lowStressShare,
                        distanceMeters: actual
                    )
                }

                radius *= target / actual
            }
        }
        return nil
    }

    // MARK: - Scoring / filters

    private static func scoreCandidate(
        lowStress: Double,
        trailShare: Double,
        overlapShare: Double,
        distanceFit: Double,
        preferTrails: Bool
    ) -> Double {
        let trailWeight = preferTrails ? 0.40 : 0.20
        let lowStressWeight = preferTrails ? 0.35 : 0.50
        let overlapWeight = preferTrails ? 0.15 : 0.20
        let fitWeight = preferTrails ? 0.10 : 0.10
        return lowStressWeight * lowStress
            + trailWeight * trailShare
            + overlapWeight * (1 - overlapShare)
            + fitWeight * distanceFit
    }

    private static func distanceFit(actual: Double, target: Double, tolerance: Double) -> Double {
        guard target > 0 else { return 0 }
        let error = abs(actual - target) / target
        if error >= tolerance { return max(0, 1 - error / max(tolerance, 0.01)) }
        return 1 - error / tolerance
    }

    private static func applyHardFilters(
        _ candidates: [LoopCandidate],
        constraints: LoopSearchConstraints
    ) -> [LoopCandidate] {
        candidates.filter { candidate in
            if let maxLTS = constraints.maxLTS {
                let violates = candidate.route.edges.contains { edge in
                    if let lts = edge.lts { return lts > maxLTS }
                    return false
                }
                if violates { return false }
            }
            if let minTrail = constraints.minTrailShare, constraints.preferTrails {
                if candidate.trailShare + 1e-9 < minTrail { return false }
            }
            let target = constraints.targetDistanceMeters
            let error = abs(candidate.distanceMeters - target) / max(target, 1)
            return error <= constraints.tolerance
        }
    }

    private static func applyDiversity(_ ranked: [LoopCandidate]) -> [LoopCandidate] {
        var kept: [LoopCandidate] = []
        for candidate in ranked {
            let tooSimilar = kept.contains { higher in
                sharedDistanceShare(candidate.route, of: higher.route) > diversityOverlapThreshold
            }
            if !tooSimilar {
                kept.append(candidate)
            }
            if kept.count >= maxCandidates { break }
        }
        return kept
    }

    /// Fraction of `candidate`'s distance that reuses edges also present on `other`.
    static func sharedDistanceShare(_ candidate: PlannedRoute, of other: PlannedRoute) -> Double {
        let otherIDs = Set(other.edges.map(\.id))
        let total = candidate.totalDistanceMeters
        guard total > 0 else { return 0 }
        let shared = candidate.edges.reduce(0.0) { sum, edge in
            otherIDs.contains(edge.id) ? sum + edge.lengthMeters : sum
        }
        return shared / total
    }

    // MARK: - Naming / geometry

    static func name(for route: PlannedRoute, bearingDegrees: Double) -> String {
        let names = route.dominantNames
            .map { NameNormalizer.routeLabel($0) }
            .filter { !$0.isEmpty }
        if names.count >= 2 {
            return "\(names[0]) and \(names[1]) Loop"
        }
        if let only = names.first {
            return "\(only) Loop"
        }
        return "\(cardinalName(degrees: bearingDegrees)) Loop"
    }

    static func cardinalName(degrees: Double) -> String {
        let names = [
            "North", "Northeast", "East", "Southeast",
            "South", "Southwest", "West", "Northwest"
        ]
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let index = Int(floor((normalized + 22.5) / 45.0)) % 8
        return names[index]
    }

    private static func coordinate(
        from origin: LocalPoint,
        bearingDegrees: Double,
        distanceMeters: Double,
        projection: LocalProjection
    ) -> CLLocationCoordinate2D {
        let radians = bearingDegrees * .pi / 180
        // Bearing 0 = north = +y; 90 = east = +x.
        let point = LocalPoint(
            x: origin.x + distanceMeters * sin(radians),
            y: origin.y + distanceMeters * cos(radians)
        )
        return projection.toCoordinate(point)
    }
}
