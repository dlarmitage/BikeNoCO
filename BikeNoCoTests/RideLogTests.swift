import XCTest
import CoreLocation
import SwiftData
@testable import BikeNoCo

@MainActor
final class RideLogTests: XCTestCase {
    private let config = BikeNetworkGraphBuilder.Config(
        endpointSnapMeters: 12,
        tJunctionSnapMeters: 8,
        gapSearchMeters: 25,
        originLatitude: 40.5,
        originLongitude: -105.0
    )

    private var projection: LocalProjection {
        LocalProjection(originLatitude: config.originLatitude, originLongitude: config.originLongitude)
    }

    private var container: ModelContainer!
    private var store: RideStore!

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true)
        store = RideStore(container: container)
    }

    // MARK: - Track codec / round-trip

    func testVersionedSchemaContainerOpens() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = RideStore(container: container)
        XCTAssertTrue(try store.allRides().isEmpty)
        XCTAssertTrue(try store.allRoutes().isEmpty)
        XCTAssertEqual(BikeNoCoSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertEqual(BikeNoCoMigrationPlan.schemas.count, 1)
    }

    func testSavedRideRoundTripPreservesTrackWithinTolerance() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [TrackPoint] = []
        for i in 0..<40 {
            let t = start.addingTimeInterval(Double(i) * 2.5)
            points.append(
                TrackPoint(
                    coordinate: at(LocalPoint(x: Double(i) * 12, y: sin(Double(i) / 3) * 5)),
                    altitude: 1_500 + Double(i) * 0.4,
                    speed: 5.5 + Double(i % 5) * 0.1,
                    timestamp: t,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 4
                )
            )
        }
        let session = RideSession.calculate(
            points: points,
            start: start,
            end: start.addingTimeInterval(100),
            movingDuration: 95,
            weightKilograms: 70
        )
        XCTAssertGreaterThan(session.distanceMeters, 200)

        let saved = try store.saveRide(session: session, wasNavigated: false, force: true)
        XCTAssertNotNil(saved)

        let fetched = try store.fetchRide(id: session.id)
        XCTAssertNotNil(fetched)
        let restored = try fetched!.toSession()

        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.trackPoints.count, session.trackPoints.count)
        XCTAssertEqual(restored.distanceMeters, session.distanceMeters, accuracy: 0.01)
        XCTAssertEqual(restored.movingDuration, session.movingDuration, accuracy: 0.01)

        for (a, b) in zip(session.trackPoints, restored.trackPoints) {
            let locA = CLLocation(latitude: a.coordinate.latitude, longitude: a.coordinate.longitude)
            let locB = CLLocation(latitude: b.coordinate.latitude, longitude: b.coordinate.longitude)
            XCTAssertLessThanOrEqual(locA.distance(from: locB), 0.2, "coordinate within 0.2 m")
            XCTAssertEqual(a.timestamp.timeIntervalSince1970, b.timestamp.timeIntervalSince1970, accuracy: 1.0)
            XCTAssertEqual(a.altitude, b.altitude, accuracy: 0.02)
            XCTAssertEqual(a.speed, b.speed, accuracy: 0.002)
        }
    }

    func testShortRideIsNotAutoSaved() throws {
        let start = Date()
        let points = [
            TrackPoint(
                coordinate: at(LocalPoint(x: 0, y: 0)),
                altitude: 1500, speed: 4, timestamp: start,
                horizontalAccuracy: 5, verticalAccuracy: 5
            ),
            TrackPoint(
                coordinate: at(LocalPoint(x: 50, y: 0)),
                altitude: 1500, speed: 4, timestamp: start.addingTimeInterval(20),
                horizontalAccuracy: 5, verticalAccuracy: 5
            )
        ]
        let session = RideSession.calculate(
            points: points,
            start: start,
            end: start.addingTimeInterval(30),
            movingDuration: 30
        )
        XCTAssertLessThan(session.distanceMeters, RideStore.minAutoSaveDistanceMeters)
        XCTAssertFalse(RideStore.shouldAutoSave(session: session))

        let saved = try store.saveRide(session: session, wasNavigated: false)
        XCTAssertNil(saved)
        XCTAssertTrue(try store.allRides().isEmpty)
    }

    func testForcedSavePersistsShortRide() throws {
        let start = Date()
        let points = [
            TrackPoint(
                coordinate: at(LocalPoint(x: 0, y: 0)),
                altitude: 1500, speed: 4, timestamp: start,
                horizontalAccuracy: 5, verticalAccuracy: 5
            ),
            TrackPoint(
                coordinate: at(LocalPoint(x: 40, y: 0)),
                altitude: 1500, speed: 4, timestamp: start.addingTimeInterval(15),
                horizontalAccuracy: 5, verticalAccuracy: 5
            )
        ]
        let session = RideSession.calculate(
            points: points,
            start: start,
            end: start.addingTimeInterval(20),
            movingDuration: 20
        )
        let saved = try store.saveRide(session: session, wasNavigated: false, force: true)
        XCTAssertNotNil(saved)
        XCTAssertEqual(try store.allRides().count, 1)
    }

    // MARK: - Track → route

    func testTrackToRouteReproducesZigzagWithHighMatch() throws {
        // Zigzag corridor: horizontal runs joined by short north/south connectors.
        let segments: [[LocalPoint]] = [
            [LocalPoint(x: 0, y: 0), LocalPoint(x: 500, y: 0)],
            [LocalPoint(x: 500, y: 0), LocalPoint(x: 500, y: 200)],
            [LocalPoint(x: 500, y: 200), LocalPoint(x: 1_000, y: 200)],
            [LocalPoint(x: 1_000, y: 200), LocalPoint(x: 1_000, y: 0)],
            [LocalPoint(x: 1_000, y: 0), LocalPoint(x: 1_500, y: 0)]
        ]
        let routes = segments.enumerated().map { index, points in
            route(points: points, name: "Zig \(index)", facility: .pavedTrail)
        }
        let graph = BikeNetworkGraphBuilder.build(from: routes, config: config)

        // Dense track following the network with a few meters of GPS jitter.
        var track: [CLLocationCoordinate2D] = []
        let path: [LocalPoint] = [
            LocalPoint(x: 0, y: 0),
            LocalPoint(x: 500, y: 0),
            LocalPoint(x: 500, y: 200),
            LocalPoint(x: 1_000, y: 200),
            LocalPoint(x: 1_000, y: 0),
            LocalPoint(x: 1_500, y: 0)
        ]
        for i in 0..<(path.count - 1) {
            let a = path[i]
            let b = path[i + 1]
            let steps = 25
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                let jitter = (step % 2 == 0) ? 1.5 : -1.5
                track.append(
                    at(LocalPoint(
                        x: a.x + (b.x - a.x) * t + jitter * 0.2,
                        y: a.y + (b.y - a.y) * t + jitter * 0.2
                    ))
                )
            }
        }
        track.append(at(path.last!))

        let result = TrackToRouteConverter.convert(track: track, graph: graph)
        guard case .success(let converted) = result else {
            return XCTFail("Expected conversion, got \(result)")
        }
        XCTAssertGreaterThanOrEqual(
            converted.matchQuality,
            0.90,
            "match quality \(converted.matchQuality)"
        )
        XCTAssertGreaterThanOrEqual(converted.waypoints.count, 2)
    }

    // MARK: - Auto-link

    func testAutoLinkMatchesSimilarRideAndRejectsHalfOverlap() throws {
        let fullPath = densify([
            LocalPoint(x: 0, y: 0),
            LocalPoint(x: 1_000, y: 0),
            LocalPoint(x: 1_000, y: 400)
        ], spacing: 20)

        let routeCoords = fullPath.map { at($0) }
        let routeDistance = pathLength(fullPath)
        let saved = try SavedRoute(
            name: "Test Corridor",
            waypoints: routeCoords,
            totalDistanceMeters: routeDistance,
            lowStressShare: 0.9
        )
        store.modelContext.insert(saved)
        try store.modelContext.save()

        // Near-identical ride should link.
        let matchSession = makeSession(along: fullPath, movingSeconds: 400)
        let linked = try store.saveRide(session: matchSession, wasNavigated: false, force: true)
        XCTAssertEqual(linked?.route?.id, saved.id)

        // Only first half of the corridor — should not link.
        let half = Array(fullPath.prefix(fullPath.count / 2))
        let halfSession = makeSession(along: half, movingSeconds: 250)
        let unlinked = try store.saveRide(session: halfSession, wasNavigated: false, force: true)
        XCTAssertNil(unlinked?.route)
    }

    // MARK: - Personal best / delete route

    func testPersonalBestAcrossThreeRides() throws {
        let route = try SavedRoute(
            name: "PB Loop",
            waypoints: [at(LocalPoint(x: 0, y: 0)), at(LocalPoint(x: 500, y: 0))],
            totalDistanceMeters: 500,
            lowStressShare: 1
        )
        store.modelContext.insert(route)

        let start = Date()
        let rides: [(TimeInterval, UUID)] = [
            (600, UUID()),
            (540, UUID()),
            (570, UUID())
        ]
        for (index, entry) in rides.enumerated() {
            let session = RideSession(
                id: entry.1,
                startDate: start.addingTimeInterval(Double(index) * 3_600),
                endDate: start.addingTimeInterval(Double(index) * 3_600 + entry.0),
                trackPoints: [
                    TrackPoint(
                        coordinate: at(LocalPoint(x: 0, y: 0)),
                        altitude: 1500, speed: 5,
                        timestamp: start.addingTimeInterval(Double(index) * 3_600),
                        horizontalAccuracy: 5, verticalAccuracy: 5
                    ),
                    TrackPoint(
                        coordinate: at(LocalPoint(x: 500, y: 0)),
                        altitude: 1500, speed: 5,
                        timestamp: start.addingTimeInterval(Double(index) * 3_600 + entry.0),
                        horizontalAccuracy: 5, verticalAccuracy: 5
                    )
                ],
                distanceMeters: 500,
                avgSpeedMPS: 500 / entry.0,
                maxSpeedMPS: 8,
                elevationGainMeters: 10,
                elevationLossMeters: 8,
                estimatedCalories: 100,
                movingDuration: entry.0
            )
            let ride = try SavedRide(session: session, wasNavigated: true, route: route)
            store.modelContext.insert(ride)
        }
        try store.modelContext.save()

        XCTAssertEqual(route.bestMovingDuration ?? -1, 540, accuracy: 0.1)
        let ordered = route.rides.sorted { $0.startDate < $1.startDate }
        XCTAssertFalse(route.isPersonalBest(ordered[0]))
        XCTAssertTrue(route.isPersonalBest(ordered[1]))
        XCTAssertFalse(route.isPersonalBest(ordered[2]))
        XCTAssertEqual(route.rideOrdinal(for: ordered[0]), 1)
        XCTAssertEqual(route.rideOrdinal(for: ordered[1]), 2)
        XCTAssertEqual(route.rideOrdinal(for: ordered[2]), 3)
    }

    func testDeletingRouteKeepsRidesUnlinked() throws {
        let route = try SavedRoute(
            name: "Temp",
            waypoints: [at(LocalPoint(x: 0, y: 0)), at(LocalPoint(x: 100, y: 0))],
            totalDistanceMeters: 100,
            lowStressShare: 1
        )
        store.modelContext.insert(route)

        let session = makeSession(along: [LocalPoint(x: 0, y: 0), LocalPoint(x: 100, y: 0)], movingSeconds: 200)
        let ride = try SavedRide(session: session, wasNavigated: false, route: route)
        store.modelContext.insert(ride)
        try store.modelContext.save()
        XCTAssertEqual(try store.allRides().count, 1)
        XCTAssertEqual(try store.allRoutes().count, 1)

        try store.deleteRoute(route)

        XCTAssertTrue(try store.allRoutes().isEmpty)
        let remaining = try store.allRides()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNil(remaining[0].route)
    }

    // MARK: - Helpers

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func route(
        points: [LocalPoint],
        name: String,
        facility: FacilityType
    ) -> BikeRoute {
        BikeRoute(
            id: UUID(),
            objectId: Int.random(in: 1...10_000),
            streetName: name,
            facilityType: facility,
            lts: nil,
            mapSymbolClass: nil,
            bikewayName: name,
            speedLimit: nil,
            paths: [points.map { at($0) }]
        )
    }

    private func densify(_ points: [LocalPoint], spacing: Double) -> [LocalPoint] {
        guard points.count >= 2 else { return points }
        var result: [LocalPoint] = [points[0]]
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let len = a.distance(to: b)
            let steps = max(1, Int(ceil(len / spacing)))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                result.append(LocalPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return result
    }

    private func pathLength(_ points: [LocalPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += points[i - 1].distance(to: points[i])
        }
        return total
    }

    private func makeSession(along points: [LocalPoint], movingSeconds: TimeInterval) -> RideSession {
        let start = Date()
        let coords = densify(points, spacing: 15)
        var track: [TrackPoint] = []
        for (index, point) in coords.enumerated() {
            let t = start.addingTimeInterval(movingSeconds * Double(index) / Double(max(coords.count - 1, 1)))
            track.append(
                TrackPoint(
                    coordinate: at(point),
                    altitude: 1500,
                    speed: 5,
                    timestamp: t,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }
        return RideSession.calculate(
            points: track,
            start: start,
            end: start.addingTimeInterval(movingSeconds),
            movingDuration: movingSeconds,
            weightKilograms: 70
        )
    }
}
