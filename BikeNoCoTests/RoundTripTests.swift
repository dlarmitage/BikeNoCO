import XCTest
import CoreLocation
@testable import BikeNoCo

final class RoundTripTests: XCTestCase {
    private let projection = LocalProjection(originLatitude: 40.5, originLongitude: -105.0)

    func testAsRoundTripDoublesDistanceAndStats() {
        let oneWay = straightRoute(length: 400, name: "Trail")
        let round = oneWay.asOutAndBack()

        XCTAssertTrue(round.isOutAndBack)
        XCTAssertEqual(round.tripShape, .outAndBack)
        XCTAssertEqual(round.legs.count, 2)
        XCTAssertEqual(round.legs[0].edgeCount, oneWay.edges.count)
        XCTAssertEqual(round.outboundDistanceMeters!, oneWay.totalDistanceMeters, accuracy: 0.1)
        XCTAssertEqual(round.outboundEdgeCount, oneWay.edges.count)
        XCTAssertEqual(round.totalDistanceMeters, oneWay.totalDistanceMeters * 2, accuracy: 0.1)
        XCTAssertEqual(round.lowStressShare, oneWay.lowStressShare, accuracy: 0.001)
        XCTAssertEqual(round.origin.latitude, oneWay.origin.latitude, accuracy: 1e-8)
        XCTAssertEqual(round.origin.longitude, oneWay.origin.longitude, accuracy: 1e-8)
        XCTAssertEqual(round.destination.latitude, oneWay.origin.latitude, accuracy: 1e-8)
        XCTAssertEqual(round.destination.longitude, oneWay.origin.longitude, accuracy: 1e-8)
        XCTAssertEqual(round.edges.count, oneWay.edges.count * 2)
        XCTAssertGreaterThan(round.coordinates.count, oneWay.coordinates.count)
    }

    func testRoundTripManeuversIncludeTurnaroundAndArriveHome() {
        let oneWay = leftTurnRoute()
        let round = oneWay.asOutAndBack()
        let maneuvers = ManeuverBuilder.build(from: round)

        XCTAssertEqual(maneuvers.first?.type, .depart)
        XCTAssertEqual(maneuvers.last?.type, .arrive)
        guard let arrive = maneuvers.last else {
            return XCTFail("Expected arrive maneuver")
        }
        XCTAssertEqual(arrive.coordinate.latitude, round.origin.latitude, accuracy: 1e-6)
        XCTAssertEqual(arrive.coordinate.longitude, round.origin.longitude, accuracy: 1e-6)

        let turnaround = maneuvers.first { $0.type == .uTurn }
        XCTAssertNotNil(turnaround)
        XCTAssertEqual(turnaround?.instruction, ManeuverBuilder.outAndBackTurnaroundInstruction)
        XCTAssertEqual(
            turnaround?.distanceAlongRoute ?? -1,
            round.outboundDistanceMeters!,
            accuracy: 1.0
        )

        // Exactly one turnaround cue.
        XCTAssertEqual(maneuvers.filter { $0.instruction == ManeuverBuilder.outAndBackTurnaroundInstruction }.count, 1)
    }

    func testNavigationSpeaksTurnaroundCue() {
        let oneWay = straightRoute(length: 400, name: "Trail")
        let round = oneWay.asOutAndBack()
        let maneuvers = ManeuverBuilder.build(from: round)
        XCTAssertFalse(
            maneuvers.contains {
                $0.type == .uTurn && $0.instruction != ManeuverBuilder.outAndBackTurnaroundInstruction
            },
            "Round trip should not emit a generic Make-a-U-turn cusp cue: \(maneuvers.map(\.instruction))"
        )

        let engine = NavigationEngine()
        var prompts: [(String, NavigationPromptKind)] = []
        engine.onEvent { event in
            if case let .prompt(text, kind) = event {
                prompts.append((text, kind))
            }
        }
        engine.start(route: round, maneuvers: maneuvers, rerouteHandler: nil)

        // At the start, nothing should speak yet — especially not a generic U-turn.
        engine.update(location: fix(x: 5, speed: 5))
        XCTAssertFalse(
            prompts.contains { $0.0.lowercased().contains("make a u-turn") },
            "Should not announce Make a U-turn at start, got \(prompts)"
        )

        // Approach turnaround from outside the far window, then enter far then near.
        let outbound = round.outboundDistanceMeters!
        engine.update(location: fix(x: outbound - 200, speed: 5))
        engine.update(location: fix(x: outbound - 140, speed: 5))
        XCTAssertTrue(
            prompts.contains { $0.1 == .far && $0.0.lowercased().contains("turn around") },
            "Expected far turnaround prompt, got \(prompts)"
        )

        engine.update(location: fix(x: outbound - 20, speed: 5))
        XCTAssertTrue(
            prompts.contains {
                $0.1 == .near && $0.0 == ManeuverBuilder.outAndBackTurnaroundInstruction
            },
            "Expected near turnaround cue, got \(prompts)"
        )
        XCTAssertFalse(
            prompts.contains { $0.0.lowercased().contains("make a u-turn") },
            "Turnaround must not use generic Make a U-turn wording, got \(prompts)"
        )
    }

    func testShortRoundTripFirstCueIsTurnAroundNotGenericUTurn() {
        let oneWay = straightRoute(length: 100, name: "Trail")
        let round = oneWay.asOutAndBack()
        let maneuvers = ManeuverBuilder.build(from: round)
        let engine = NavigationEngine()
        var prompts: [String] = []
        engine.onEvent { event in
            if case let .prompt(text, _) = event { prompts.append(text) }
        }
        engine.start(route: round, maneuvers: maneuvers, rerouteHandler: nil)

        // Turnaround is within the far window from the start; skip far, then speak near.
        engine.update(location: fix(x: 5, speed: 5))
        engine.update(location: fix(x: 75, speed: 5))
        XCTAssertFalse(
            prompts.contains { $0.lowercased().contains("make a u-turn") },
            "Short round trip spoke generic U-turn: \(prompts)"
        )
        XCTAssertTrue(
            prompts.contains { $0 == ManeuverBuilder.outAndBackTurnaroundInstruction },
            "Expected turnaround cue, got \(prompts)"
        )
    }

    func testProgressTrackerDoesNotJumpAheadOnRoundTrip() {
        let oneWay = straightRoute(length: 400, name: "Trail")
        let round = oneWay.asOutAndBack()
        let maneuvers = ManeuverBuilder.build(from: round)
        var tracker = RouteProgressTracker(coordinates: round.coordinates, maneuvers: maneuvers)

        for x in stride(from: 0.0, through: 200.0, by: 10.0) {
            let progress = tracker.update(
                location: fix(x: x, y: Double.random(in: -5...5), speed: 4)
            )
            XCTAssertLessThan(
                progress.distanceAlongRoute,
                350,
                "Jumped ahead to \(progress.distanceAlongRoute) at x=\(x)"
            )
            XCTAssertEqual(progress.nextManeuver?.type, .uTurn)
        }
    }

    func testArrivalOnlyNearEndOfRoundTrip() {
        let oneWay = straightRoute(length: 100, name: "Trail")
        let round = oneWay.asOutAndBack()
        let engine = NavigationEngine()
        var arrived = false
        engine.onEvent { event in
            if case let .prompt(_, kind) = event, kind == .arrived {
                arrived = true
            }
        }
        engine.start(route: round, maneuvers: ManeuverBuilder.build(from: round), rerouteHandler: nil)

        // Still near the origin at the start of a round trip — must not arrive.
        engine.update(location: fix(x: 5, speed: 3))
        XCTAssertFalse(arrived)
        XCTAssertNotEqual(engine.state, .arrived)

        let outbound = round.outboundDistanceMeters!
        // Walk outbound, through the turnaround, then back — small steps so matching
        // cannot skip the return leg on the doubled geometry.
        for x in stride(from: 0.0, through: outbound, by: 10) {
            engine.update(location: fix(x: x, speed: 5))
        }
        for x in stride(from: outbound, through: 0.0, by: -10) {
            engine.update(location: fix(x: x, speed: 5))
        }
        engine.update(location: fix(x: 5, speed: 2))
        XCTAssertTrue(arrived, "Should arrive after completing the return leg")
        XCTAssertEqual(engine.state, .arrived)
    }

    // MARK: - Helpers

    private func straightRoute(length: Double, name: String) -> PlannedRoute {
        var coords: [CLLocationCoordinate2D] = []
        for x in stride(from: 0.0, through: length, by: 25.0) {
            coords.append(at(LocalPoint(x: x, y: 0)))
        }
        if coords.last.map({ projection.toLocal($0).x }) != length {
            coords.append(at(LocalPoint(x: length, y: 0)))
        }
        let edge = GraphEdge(
            id: 1,
            fromID: 0,
            toID: 1,
            lengthMeters: length,
            geometry: coords,
            facilityType: .pavedTrail,
            lts: nil,
            name: name,
            sourceRouteID: UUID(),
            isConnector: false
        )
        return PlannedRoute.make(
            edges: [edge],
            coordinates: coords,
            origin: coords[0],
            destination: coords.last!
        )
    }

    private func leftTurnRoute() -> PlannedRoute {
        let edges = [
            GraphEdge(
                id: 1,
                fromID: 0,
                toID: 1,
                lengthMeters: 200,
                geometry: [at(LocalPoint(x: 0, y: 0)), at(LocalPoint(x: 200, y: 0))],
                facilityType: .bikeLane,
                lts: 1,
                name: "First",
                sourceRouteID: UUID(),
                isConnector: false
            ),
            GraphEdge(
                id: 2,
                fromID: 1,
                toID: 2,
                lengthMeters: 200,
                geometry: [at(LocalPoint(x: 200, y: 0)), at(LocalPoint(x: 200, y: 200))],
                facilityType: .bikeLane,
                lts: 1,
                name: "Second",
                sourceRouteID: UUID(),
                isConnector: false
            ),
        ]
        let coords = [at(LocalPoint(x: 0, y: 0)), at(LocalPoint(x: 200, y: 0)), at(LocalPoint(x: 200, y: 200))]
        return PlannedRoute.make(
            edges: edges,
            coordinates: coords,
            origin: coords[0],
            destination: coords.last!
        )
    }

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func fix(x: Double, y: Double = 0, speed: Double, accuracy: Double = 5) -> CLLocation {
        CLLocation(
            coordinate: at(LocalPoint(x: x, y: y)),
            altitude: 1500,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: 90,
            speed: speed,
            timestamp: Date()
        )
    }
}
