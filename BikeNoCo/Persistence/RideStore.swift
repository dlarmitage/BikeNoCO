import Foundation
import SwiftData
import CoreLocation

/// Persistence façade for rides and saved routes.
@MainActor
final class RideStore: ObservableObject {
    static let minAutoSaveDistanceMeters = 0.1 * 1609.344
    static let minAutoSaveMovingSeconds: TimeInterval = 120

    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    convenience init(container: ModelContainer) {
        self.init(modelContext: ModelContext(container))
    }

    // MARK: - Auto-save eligibility

    static func shouldAutoSave(session: RideSession) -> Bool {
        session.distanceMeters >= minAutoSaveDistanceMeters
            && session.movingDuration >= minAutoSaveMovingSeconds
    }

    // MARK: - Rides

    @discardableResult
    func saveRide(
        session: RideSession,
        wasNavigated: Bool,
        linkedRouteID: UUID? = nil,
        graph: BikeNetworkGraph? = nil,
        force: Bool = false
    ) throws -> SavedRide? {
        if !force && !Self.shouldAutoSave(session: session) {
            return nil
        }

        if let existing = try fetchRide(id: session.id) {
            return existing
        }

        var route: SavedRoute?
        if let linkedRouteID {
            route = try fetchRoute(id: linkedRouteID)
        } else if !wasNavigated {
            route = try autoLinkRoute(for: session, graph: graph)
        }

        let ride = try SavedRide(session: session, wasNavigated: wasNavigated, route: route)
        modelContext.insert(ride)
        try modelContext.save()
        return ride
    }

    func deleteRide(_ ride: SavedRide) throws {
        modelContext.delete(ride)
        try modelContext.save()
    }

    func deleteRide(id: UUID) throws {
        guard let ride = try fetchRide(id: id) else { return }
        try deleteRide(ride)
    }

    func fetchRide(id: UUID) throws -> SavedRide? {
        var descriptor = FetchDescriptor<SavedRide>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func allRides() throws -> [SavedRide] {
        let descriptor = FetchDescriptor<SavedRide>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    // MARK: - Routes

    @discardableResult
    func createRoute(
        from session: RideSession,
        name: String,
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default
    ) throws -> (route: SavedRoute, matchQuality: Double) {
        let track = session.coordinates
        let conversion = TrackToRouteConverter.convert(track: track, graph: graph, profile: profile)
        switch conversion {
        case .failure(let error):
            throw error
        case .success(let result):
            #if DEBUG
            NSLog(
                "[BikeNoCo SavedRoute] \"%@\" match quality %.1f%%",
                name,
                result.matchQuality * 100
            )
            #endif

            let route = try SavedRoute(
                name: name,
                waypoints: result.waypoints,
                totalDistanceMeters: result.plannedRoute.totalDistanceMeters,
                lowStressShare: result.plannedRoute.lowStressShare,
                sourceRideID: session.id
            )
            modelContext.insert(route)

            if let ride = try fetchRide(id: session.id) {
                ride.route = route
            } else {
                let ride = try SavedRide(session: session, wasNavigated: false, route: route)
                modelContext.insert(ride)
            }

            try modelContext.save()
            return (route, result.matchQuality)
        }
    }

    func renameRoute(_ route: SavedRoute, to name: String) throws {
        route.name = name
        try modelContext.save()
    }

    func deleteRoute(_ route: SavedRoute) throws {
        // Nullify links; rides are kept.
        for ride in route.rides {
            ride.route = nil
        }
        modelContext.delete(route)
        try modelContext.save()
    }

    func fetchRoute(id: UUID) throws -> SavedRoute? {
        var descriptor = FetchDescriptor<SavedRoute>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func allRoutes() throws -> [SavedRoute] {
        let descriptor = FetchDescriptor<SavedRoute>(
            sortBy: [SortDescriptor(\.createdDate, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    /// Reconstructs a polyline for matching / map preview by routing the stored waypoints.
    func routedCoordinates(
        for route: SavedRoute,
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default
    ) -> [CLLocationCoordinate2D] {
        let waypoints = route.waypoints
        guard waypoints.count >= 2 else { return waypoints }
        switch RouteFinder.routeThrough(waypoints: waypoints, graph: graph, profile: profile) {
        case .success(let planned):
            return planned.coordinates
        case .failure:
            return waypoints
        }
    }

    // MARK: - Stats helpers

    struct PeriodTotals {
        var distanceMeters: Double = 0
        var movingDuration: TimeInterval = 0
        var elevationGainMeters: Double = 0
    }

    func totals(in interval: DateInterval, from rides: [SavedRide]? = nil) throws -> PeriodTotals {
        let source = try rides ?? allRides()
        var totals = PeriodTotals()
        for ride in source where interval.contains(ride.startDate) {
            totals.distanceMeters += ride.distanceMeters
            totals.movingDuration += ride.movingDuration
            totals.elevationGainMeters += ride.elevationGainMeters
        }
        return totals
    }

    /// Weekly distance buckets for the last `weekCount` ISO weeks ending this week.
    func weeklyDistances(weekCount: Int = 12, from rides: [SavedRide]? = nil, now: Date = Date()) throws -> [(weekStart: Date, distanceMeters: Double)] {
        let calendar = Calendar.current
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return []
        }
        let source = try rides ?? allRides()
        var buckets: [(Date, Double)] = []
        for offset in stride(from: weekCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeekStart),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else {
                continue
            }
            let interval = DateInterval(start: start, end: end)
            let distance = source
                .filter { interval.contains($0.startDate) }
                .reduce(0.0) { $0 + $1.distanceMeters }
            buckets.append((start, distance))
        }
        return buckets
    }

    // MARK: - Private

    private func autoLinkRoute(
        for session: RideSession,
        graph: BikeNetworkGraph?
    ) throws -> SavedRoute? {
        let routes = try allRoutes()
        guard !routes.isEmpty else { return nil }

        let densified: [(id: UUID, coordinates: [CLLocationCoordinate2D], distanceMeters: Double)] =
            routes.map { route in
                let coordinates: [CLLocationCoordinate2D]
                if let graph, route.waypoints.count >= 2 {
                    coordinates = routedCoordinates(for: route, graph: graph)
                } else {
                    coordinates = densify(route.waypoints, spacingMeters: 25)
                }
                return (route.id, coordinates, route.totalDistanceMeters)
            }

        guard let matchID = RouteMatcher.bestMatch(
            track: session.coordinates,
            trackDistanceMeters: session.distanceMeters,
            candidates: densified
        ) else {
            return nil
        }
        return routes.first { $0.id == matchID }
    }

    private func densify(
        _ coordinates: [CLLocationCoordinate2D],
        spacingMeters: Double
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return coordinates }
        let geometry = PolylineProximity.cumulativeDistances(coordinates)
        var result: [CLLocationCoordinate2D] = [coordinates[0]]
        var d = spacingMeters
        while d < geometry.total {
            let point = PolylineProximity.point(
                at: d,
                locals: geometry.locals,
                cumulative: geometry.cumulative
            )
            result.append(geometry.projection.toCoordinate(point))
            d += spacingMeters
        }
        if let last = coordinates.last {
            result.append(last)
        }
        return result
    }
}

extension RoutingError: LocalizedError {
    public var errorDescription: String? { friendlyMessage }
}
