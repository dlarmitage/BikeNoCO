import XCTest
import CoreLocation
import SwiftData
@testable import BikeNoCo

/// End-to-end persistence flow mirroring Simulate Ride → star → ride again.
@MainActor
final class RideLogFlowTests: XCTestCase {
    func testOldTownToCSUStarAndSecondRideOrdinal() async throws {
        let graph = try await loadGraph()
        let oldTown = CLLocationCoordinate2D(latitude: 40.5875, longitude: -105.0760)
        let csu = CLLocationCoordinate2D(latitude: 40.5750, longitude: -105.0820)

        let routed = RouteFinder.route(from: oldTown, to: csu, graph: graph)
        guard case .success(let planned) = routed else {
            return XCTFail("Expected Old Town → CSU route, got \(routed)")
        }
        XCTAssertGreaterThan(planned.totalDistanceMeters, 500)

        let track = densify(planned.coordinates, spacingMeters: 8)
        let session1 = makeSession(along: track, movingSeconds: max(180, planned.totalDistanceMeters / 5))

        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = RideStore(container: container)

        let saved1 = try store.saveRide(
            session: session1,
            wasNavigated: true,
            force: true
        )
        XCTAssertNotNil(saved1)

        let starred = try store.createRoute(
            from: session1,
            name: TrackToRouteConverter.suggestedName(for: planned),
            graph: graph
        )
        NSLog(
            "[BikeNoCo] Add to My Routes \"%@\" match quality %.1f%%",
            starred.route.name,
            starred.matchQuality * 100
        )
        XCTAssertGreaterThanOrEqual(
            starred.matchQuality,
            0.90,
            "Old Town → CSU match quality should be ≥ 90%"
        )
        XCTAssertEqual(try store.allRoutes().count, 1)

        // Second ride of the same saved route (navigated link).
        let session2 = makeSession(
            along: track,
            movingSeconds: max(170, planned.totalDistanceMeters / 5.2),
            id: UUID()
        )
        let saved2 = try store.saveRide(
            session: session2,
            wasNavigated: true,
            linkedRouteID: starred.route.id,
            force: true
        )
        XCTAssertNotNil(saved2)
        XCTAssertEqual(saved2?.route?.id, starred.route.id)
        XCTAssertEqual(starred.route.timesRidden, 2)
        XCTAssertEqual(starred.route.rideOrdinal(for: saved2!), 2)

        NSLog(
            "[BikeNoCo Flow] 2nd time on %@ — match was %.1f%%",
            starred.route.name,
            starred.matchQuality * 100
        )
    }

    // MARK: - Helpers

    private func loadGraph() async throws -> BikeNetworkGraph {
        if let cached = try? GraphCache.load() {
            return cached.graph
        }
        let routes = try await ArcGISService().fetchAllRoutes { _ in }
        let file = try OSMConnectorLoader.loadBundled()
        return BikeNetworkGraphBuilder.build(from: routes, connectors: file.edges).graph
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
        if let last = coordinates.last { result.append(last) }
        return result
    }

    private func makeSession(
        along coordinates: [CLLocationCoordinate2D],
        movingSeconds: TimeInterval,
        id: UUID = UUID()
    ) -> RideSession {
        let start = Date()
        var points: [TrackPoint] = []
        for (index, coordinate) in coordinates.enumerated() {
            let t = start.addingTimeInterval(
                movingSeconds * Double(index) / Double(max(coordinates.count - 1, 1))
            )
            points.append(
                TrackPoint(
                    coordinate: coordinate,
                    altitude: 1_520,
                    speed: 5.5,
                    timestamp: t,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }
        var session = RideSession.calculate(
            points: points,
            start: start,
            end: start.addingTimeInterval(movingSeconds),
            movingDuration: movingSeconds,
            weightKilograms: 70
        )
        // Preserve a stable id for linking assertions.
        session = RideSession(
            id: id,
            startDate: session.startDate,
            endDate: session.endDate,
            trackPoints: session.trackPoints,
            distanceMeters: session.distanceMeters,
            avgSpeedMPS: session.avgSpeedMPS,
            maxSpeedMPS: session.maxSpeedMPS,
            elevationGainMeters: session.elevationGainMeters,
            elevationLossMeters: session.elevationLossMeters,
            estimatedCalories: session.estimatedCalories,
            movingDuration: session.movingDuration
        )
        return session
    }
}
