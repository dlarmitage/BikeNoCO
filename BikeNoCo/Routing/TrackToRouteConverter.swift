import Foundation
import CoreLocation

struct TrackToRouteResult {
    let waypoints: [CLLocationCoordinate2D]
    let plannedRoute: PlannedRoute
    /// Share of routed distance within 30 m of the recorded track.
    let matchQuality: Double
}

/// Converts a GPS track into routing waypoints, then refines against the network.
enum TrackToRouteConverter {
    private static let sampleSpacingMeters = 400.0
    private static let headingSmoothMeters = 30.0
    private static let sharpTurnDegrees = 45.0
    private static let divergeMeters = 40.0
    private static let minDivergeSpanMeters = 150.0
    private static let matchThresholdMeters = 30.0
    private static let maxRefinementPasses = 3

    static func convert(
        track: [CLLocationCoordinate2D],
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default
    ) -> Result<TrackToRouteResult, RoutingError> {
        guard track.count >= 2 else {
            return .failure(.noPath(hint: "Track is too short to save as a route."))
        }

        var waypoints = sampleWaypoints(from: track)
        var lastRoute: PlannedRoute?
        var lastQuality = 0.0

        for pass in 0...maxRefinementPasses {
            let routed = RouteFinder.routeThrough(
                waypoints: waypoints,
                graph: graph,
                profile: profile
            )
            switch routed {
            case .failure(let error):
                if let lastRoute {
                    return .success(
                        TrackToRouteResult(
                            waypoints: waypoints,
                            plannedRoute: lastRoute,
                            matchQuality: lastQuality
                        )
                    )
                }
                return .failure(error)
            case .success(let planned):
                let quality = PolylineProximity.lengthShareWithin(
                    sample: planned.coordinates,
                    of: track,
                    thresholdMeters: matchThresholdMeters
                )
                lastRoute = planned
                lastQuality = quality

                #if DEBUG
                NSLog(
                    "[BikeNoCo TrackToRoute] pass %d: waypoints=%d match=%.1f%% distance=%.0fm",
                    pass,
                    waypoints.count,
                    quality * 100,
                    planned.totalDistanceMeters
                )
                #endif

                if pass == maxRefinementPasses {
                    break
                }

                let spans = PolylineProximity.divergenceSpans(
                    routed: planned.coordinates,
                    track: track,
                    divergeMeters: divergeMeters,
                    minSpanMeters: minDivergeSpanMeters
                )
                if spans.isEmpty {
                    break
                }

                waypoints = insertWaypoints(spans.map(\.insertCoordinate), into: waypoints, along: track)
            }
        }

        guard let planned = lastRoute else {
            return .failure(.noPath(hint: "Could not route the recorded track."))
        }
        return .success(
            TrackToRouteResult(
                waypoints: waypoints,
                plannedRoute: planned,
                matchQuality: lastQuality
            )
        )
    }

    /// Closed enough to treat as a loop when naming (start ≈ end).
    static let loopClosureMeters: Double = 200

    /// Suggested display name from named runs along the converted route.
    /// Loops (start/end within 200 m): `"Spring Creek and Poudre Trail Loop"`.
    /// Open rides: `"Laurel St to Mason Trail"`.
    static func suggestedName(for planned: PlannedRoute) -> String {
        let bearing = routeBearing(for: planned)
        if isClosedLoop(planned, withinMeters: loopClosureMeters) {
            return loopName(for: planned, bearingDegrees: bearing)
        }
        return openName(for: planned, bearingDegrees: bearing)
    }

    static func isClosedLoop(_ planned: PlannedRoute, withinMeters: Double = loopClosureMeters) -> Bool {
        guard let start = planned.coordinates.first, let end = planned.coordinates.last else {
            return false
        }
        let a = CLLocation(latitude: start.latitude, longitude: start.longitude)
        let b = CLLocation(latitude: end.latitude, longitude: end.longitude)
        return a.distance(from: b) <= withinMeters
    }

    /// Named runs in route order (consecutive same-normalized names collapsed).
    static func orderedNamedRuns(in planned: PlannedRoute) -> [String] {
        var runs: [String] = []
        var lastKey: String?
        for edge in planned.edges {
            let trimmed = edge.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = NameNormalizer.normalize(trimmed)
            guard !key.isEmpty else { continue }
            if key != lastKey {
                let label = NameNormalizer.routeLabel(trimmed)
                if !label.isEmpty {
                    runs.append(label)
                }
                lastKey = key
            }
        }
        return runs
    }

    private static func loopName(for planned: PlannedRoute, bearingDegrees: Double) -> String {
        let names = planned.dominantNames
            .map { NameNormalizer.routeLabel($0) }
            .filter { !$0.isEmpty }
        if names.count >= 2 {
            return "\(names[0]) and \(names[1]) Loop"
        }
        if let only = names.first {
            return "\(only) Loop"
        }
        return "\(DistanceLoopPlanner.cardinalName(degrees: bearingDegrees)) Loop"
    }

    private static func openName(for planned: PlannedRoute, bearingDegrees: Double) -> String {
        let runs = orderedNamedRuns(in: planned)
        if runs.count >= 2, let first = runs.first, let last = runs.last, first != last {
            return "\(first) to \(last)"
        }
        if let only = runs.first {
            return only
        }
        return DistanceLoopPlanner.cardinalName(degrees: bearingDegrees)
    }

    private static func routeBearing(for planned: PlannedRoute) -> Double {
        guard planned.coordinates.count >= 2 else { return 0 }
        let start = planned.coordinates[0]
        let mid = planned.coordinates[planned.coordinates.count / 2]
        return initialBearing(from: start, to: mid)
    }

    // MARK: - Sampling

    static func sampleWaypoints(from track: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        let geometry = PolylineProximity.cumulativeDistances(track)
        let locals = geometry.locals
        let cumulative = geometry.cumulative
        let total = geometry.total
        let projection = geometry.projection

        guard locals.count >= 2, total > 1 else {
            return [track.first, track.last].compactMap { $0 }
        }

        var waypoints: [CLLocationCoordinate2D] = [track[0]]
        var lastKeptDistance = 0.0

        // Sharp heading changes over a 30 m smoothed window.
        var distance = headingSmoothMeters
        var previousHeading: Double?
        while distance <= total - headingSmoothMeters {
            let back = max(0, distance - headingSmoothMeters)
            let forward = min(total, distance + headingSmoothMeters)
            if let heading = bearing(
                from: PolylineProximity.point(at: back, locals: locals, cumulative: cumulative),
                to: PolylineProximity.point(at: forward, locals: locals, cumulative: cumulative)
            ) {
                if let previous = previousHeading {
                    let delta = abs(signedAngleDegrees(from: previous, to: heading))
                    if delta >= sharpTurnDegrees, distance - lastKeptDistance >= 40 {
                        waypoints.append(
                            projection.toCoordinate(
                                PolylineProximity.point(at: distance, locals: locals, cumulative: cumulative)
                            )
                        )
                        lastKeptDistance = distance
                    }
                }
                previousHeading = heading
            }
            distance += 10
        }

        // Regular samples every ~400 m.
        var sampleAt = sampleSpacingMeters
        while sampleAt < total - 20 {
            if sampleAt - lastKeptDistance >= sampleSpacingMeters * 0.5 {
                waypoints.append(
                    projection.toCoordinate(
                        PolylineProximity.point(at: sampleAt, locals: locals, cumulative: cumulative)
                    )
                )
                lastKeptDistance = sampleAt
            }
            sampleAt += sampleSpacingMeters
        }

        if let last = track.last {
            if waypoints.last.map({
                abs($0.latitude - last.latitude) > 1e-7 || abs($0.longitude - last.longitude) > 1e-7
            }) ?? true {
                waypoints.append(last)
            }
        }

        // Keep order along the track by projecting each waypoint.
        return waypoints
    }

    // MARK: - Helpers

    private static func insertWaypoints(
        _ inserts: [CLLocationCoordinate2D],
        into waypoints: [CLLocationCoordinate2D],
        along track: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        let geometry = PolylineProximity.cumulativeDistances(track)
        func along(_ coordinate: CLLocationCoordinate2D) -> Double {
            let local = geometry.projection.toLocal(coordinate)
            return PolylineProximity.nearestPoint(on: geometry.locals, to: local).tAlong
        }

        var combined = waypoints + inserts
        combined.sort { along($0) < along($1) }

        // Deduplicate near-identical points.
        var deduped: [CLLocationCoordinate2D] = []
        for coordinate in combined {
            if let last = deduped.last {
                let a = CLLocation(latitude: last.latitude, longitude: last.longitude)
                let b = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                if a.distance(from: b) < 15 { continue }
            }
            deduped.append(coordinate)
        }
        return deduped
    }

    private static func bearing(from a: LocalPoint, to b: LocalPoint) -> Double? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        guard hypot(dx, dy) > 1e-6 else { return nil }
        var degrees = atan2(dx, dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private static func signedAngleDegrees(from a: Double, to b: Double) -> Double {
        var delta = b - a
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private static func initialBearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        var degrees = atan2(y, x) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }
}
