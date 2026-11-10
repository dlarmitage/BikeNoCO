import XCTest
import CoreLocation
@testable import BikeNoCo

final class NavigationEngineTests: XCTestCase {
    private let projection = LocalProjection(originLatitude: 40.5, originLongitude: -105.0)

    func testFarThenNearFireOnceAndSpeedScalingMovesTriggers() {
        let route = straightRoute(length: 400)
        let turn = Maneuver(
            type: .left,
            coordinate: at(LocalPoint(x: 300, y: 0)),
            distanceAlongRoute: 300,
            distanceToNext: 100,
            streetName: "Mason Trail",
            instruction: "Turn left onto Mason Trail"
        )
        let maneuvers = [
            Maneuver(
                type: .depart,
                coordinate: route.coordinates[0],
                distanceAlongRoute: 0,
                distanceToNext: 300,
                streetName: "Path",
                instruction: "Head east"
            ),
            turn,
            Maneuver(
                type: .arrive,
                coordinate: route.coordinates.last!,
                distanceAlongRoute: 400,
                distanceToNext: 0,
                streetName: nil,
                instruction: "Arrive at destination"
            ),
        ]

        let engine = NavigationEngine()
        var prompts: [(String, NavigationPromptKind)] = []
        engine.onEvent { event in
            if case let .prompt(text, kind) = event {
                prompts.append((text, kind))
            }
        }
        engine.start(route: route, maneuvers: maneuvers, rerouteHandler: nil)

        // Approach from outside far window so far is eligible.
        engine.update(location: fix(x: 100, speed: 5))
        XCTAssertTrue(prompts.isEmpty)

        engine.update(location: fix(x: 160, speed: 5)) // 140 m to turn
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].1, .far)
        XCTAssertTrue(prompts[0].0.lowercased().contains("turn left"))

        engine.update(location: fix(x: 150, speed: 5))
        XCTAssertEqual(prompts.count, 1, "Far must fire only once")

        engine.update(location: fix(x: 275, speed: 5)) // 25 m to turn
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts[1].1, .near)
        XCTAssertEqual(prompts[1].0, "Turn left")

        engine.update(location: fix(x: 290, speed: 5))
        XCTAssertEqual(prompts.count, 2, "Near must fire only once")

        // Speed scaling: above 20 mph, far threshold is 225 m.
        let scale = NavigationEngine.promptDistanceScale(speed: 12) // ~26.8 mph
        XCTAssertEqual(scale, 1.5, accuracy: 0.01)
        let scaledFar = 150.0 * scale
        XCTAssertEqual(scaledFar, 225, accuracy: 0.1)
    }

    func testSkipsFarWhenAlreadyInsideFarWindow() {
        let route = straightRoute(length: 200)
        let turn = Maneuver(
            type: .right,
            coordinate: at(LocalPoint(x: 100, y: 0)),
            distanceAlongRoute: 100,
            distanceToNext: 100,
            streetName: "B",
            instruction: "Turn right onto B"
        )
        let maneuvers = [
            Maneuver(
                type: .depart,
                coordinate: route.coordinates[0],
                distanceAlongRoute: 0,
                distanceToNext: 100,
                streetName: "A",
                instruction: "Head east"
            ),
            turn,
            Maneuver(
                type: .arrive,
                coordinate: route.coordinates.last!,
                distanceAlongRoute: 200,
                distanceToNext: 0,
                streetName: nil,
                instruction: "Arrive at destination"
            ),
        ]

        let engine = NavigationEngine()
        var kinds: [NavigationPromptKind] = []
        engine.onEvent { event in
            if case let .prompt(_, kind) = event { kinds.append(kind) }
        }
        engine.start(route: route, maneuvers: maneuvers, rerouteHandler: nil)

        // First fix already 80 m from the turn (inside far, outside near).
        engine.update(location: fix(x: 20, speed: 5))
        XCTAssertTrue(kinds.isEmpty, "Far should be skipped when already inside the window")

        engine.update(location: fix(x: 75, speed: 5))
        XCTAssertEqual(kinds, [.near])
    }

    func testLowAccuracyDoesNotTriggerOffRoute() {
        let route = straightRoute(length: 300)
        let engine = NavigationEngine()
        var states: [NavigationState] = []
        engine.onEvent { event in
            if case let .stateChanged(state) = event { states.append(state) }
        }
        engine.start(route: route, maneuvers: simpleManeuvers(for: route), rerouteHandler: nil)
        engine.update(location: fix(x: 10, speed: 5, accuracy: 5))

        // 40 m off route but poor accuracy.
        engine.update(location: fix(x: 50, y: 40, speed: 5, accuracy: 35))
        XCTAssertFalse(states.contains(.offRoute))
    }

    func testOffRouteTriggersOneRerouteAndRespectsCooldown() async throws {
        let route = straightRoute(length: 500)
        var clock = Date(timeIntervalSince1970: 2_000_000)
        var rerouteCount = 0

        let engine = NavigationEngine()
        var prompts: [NavigationPromptKind] = []
        engine.onEvent { event in
            if case let .prompt(_, kind) = event { prompts.append(kind) }
        }

        let replacement = straightRoute(length: 400, y: 5)
        engine.start(
            route: route,
            maneuvers: simpleManeuvers(for: route),
            rerouteHandler: { _, _ in
                rerouteCount += 1
                return .success(replacement)
            },
            now: { clock }
        )

        engine.update(location: fix(x: 20, speed: 5, timestamp: clock))

        // Go 40 m off route and hold for 6+ seconds of engine clock.
        clock = clock.addingTimeInterval(1)
        engine.update(location: fix(x: 40, y: 40, speed: 5, timestamp: clock))
        XCTAssertEqual(engine.state, .offRoute)
        clock = clock.addingTimeInterval(6)
        engine.update(location: fix(x: 45, y: 40, speed: 5, timestamp: clock))

        // Allow async reroute task to finish.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rerouteCount, 1)
        XCTAssertEqual(prompts.filter { $0 == .rerouting }.count, 1)
        XCTAssertEqual(engine.state, .navigating)

        // Second departure within 10 s must not reroute again.
        clock = clock.addingTimeInterval(2)
        engine.update(location: fix(x: 80, y: 50, speed: 5, timestamp: clock))
        XCTAssertEqual(engine.state, .offRoute)
        clock = clock.addingTimeInterval(6)
        engine.update(location: fix(x: 85, y: 55, speed: 5, timestamp: clock))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rerouteCount, 1, "Cooldown should block a second reroute")
    }

    func testArrivalFiresOnceWithin20Meters() {
        let route = straightRoute(length: 100)
        let engine = NavigationEngine()
        var prompts: [NavigationPromptKind] = []
        engine.onEvent { event in
            if case let .prompt(_, kind) = event { prompts.append(kind) }
        }
        engine.start(route: route, maneuvers: simpleManeuvers(for: route), rerouteHandler: nil)

        engine.update(location: fix(x: 50, speed: 5))
        XCTAssertFalse(prompts.contains(.arrived))

        engine.update(location: fix(x: 95, speed: 3))
        XCTAssertEqual(prompts.filter { $0 == .arrived }.count, 1)
        XCTAssertEqual(engine.state, .arrived)

        engine.update(location: fix(x: 98, speed: 1))
        XCTAssertEqual(prompts.filter { $0 == .arrived }.count, 1)
    }

    func testSpokenDistanceFormatting() {
        XCTAssertEqual(DistanceFormat.spoken(152.4), "500 feet") // ~500 ft
        XCTAssertEqual(DistanceFormat.spoken(321.87), "0.2 miles")
    }

    // MARK: - Helpers

    private func straightRoute(length: Double, y: Double = 0) -> PlannedRoute {
        var coords: [CLLocationCoordinate2D] = []
        for x in stride(from: 0.0, through: length, by: 25.0) {
            coords.append(at(LocalPoint(x: x, y: y)))
        }
        if coords.last.map({ projection.toLocal($0).x }) != length {
            coords.append(at(LocalPoint(x: length, y: y)))
        }
        let edge = GraphEdge(
            id: 1,
            fromID: 0,
            toID: 1,
            lengthMeters: length,
            geometry: coords,
            facilityType: .pavedTrail,
            lts: nil,
            name: "Test Trail",
            sourceRouteID: UUID(),
            isConnector: false,
            osmClass: nil
        )
        return PlannedRoute.make(
            edges: [edge],
            coordinates: coords,
            origin: coords[0],
            destination: coords.last!
        )
    }

    private func simpleManeuvers(for route: PlannedRoute) -> [Maneuver] {
        [
            Maneuver(
                type: .depart,
                coordinate: route.origin,
                distanceAlongRoute: 0,
                distanceToNext: route.totalDistanceMeters,
                streetName: "Test Trail",
                instruction: "Head east"
            ),
            Maneuver(
                type: .arrive,
                coordinate: route.destination,
                distanceAlongRoute: route.totalDistanceMeters,
                distanceToNext: 0,
                streetName: nil,
                instruction: "Arrive at destination"
            ),
        ]
    }

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func fix(
        x: Double,
        y: Double = 0,
        speed: Double,
        accuracy: Double = 5,
        timestamp: Date = Date()
    ) -> CLLocation {
        CLLocation(
            coordinate: at(LocalPoint(x: x, y: y)),
            altitude: 1500,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: 90,
            speed: speed,
            timestamp: timestamp
        )
    }
}
