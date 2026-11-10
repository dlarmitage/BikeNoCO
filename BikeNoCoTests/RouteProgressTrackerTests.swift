import XCTest
import CoreLocation
@testable import BikeNoCo

final class RouteProgressTrackerTests: XCTestCase {
    private let projection = LocalProjection(originLatitude: 40.5, originLongitude: -105.0)

    func testMatchesNoisyGPSWithoutSkippingAhead() {
        // Straight 500 m east route with a turn marker at 300 m.
        let coords = stride(from: 0.0, through: 500.0, by: 25.0).map { x in
            at(LocalPoint(x: x, y: 0))
        }
        let turn = Maneuver(
            type: .left,
            coordinate: at(LocalPoint(x: 300, y: 0)),
            distanceAlongRoute: 300,
            distanceToNext: 200,
            streetName: "Side",
            instruction: "Turn left onto Side"
        )
        let arrive = Maneuver(
            type: .arrive,
            coordinate: coords.last!,
            distanceAlongRoute: 500,
            distanceToNext: 0,
            streetName: nil,
            instruction: "Arrive at destination"
        )
        var tracker = RouteProgressTracker(
            coordinates: coords,
            maneuvers: [
                Maneuver(
                    type: .depart,
                    coordinate: coords[0],
                    distanceAlongRoute: 0,
                    distanceToNext: 300,
                    streetName: "Main",
                    instruction: "Head east"
                ),
                turn,
                arrive,
            ]
        )

        var sawTurnAsNext = false
        for x in stride(from: 0.0, through: 280.0, by: 10.0) {
            let noise = Double.random(in: -8...8)
            let fix = location(at: LocalPoint(x: x, y: noise), accuracy: 5, speed: 5)
            let progress = tracker.update(location: fix)
            XCTAssertTrue(progress.didMatch)
            XCTAssertLessThan(progress.distanceAlongRoute, 295, "Should not jump past the turn early")
            if progress.nextManeuver?.type == .left {
                sawTurnAsNext = true
            }
        }
        XCTAssertTrue(sawTurnAsNext)
    }

    func testOutAndBackDoesNotJumpToReturnLeg() {
        // Out 0→400 along y=0, back 400→0 along y=0 (same geometry reversed).
        var coords: [CLLocationCoordinate2D] = []
        for x in stride(from: 0.0, through: 400.0, by: 20.0) {
            coords.append(at(LocalPoint(x: x, y: 0)))
        }
        for x in stride(from: 380.0, through: 0.0, by: -20.0) {
            coords.append(at(LocalPoint(x: x, y: 0)))
        }

        let maneuvers = [
            Maneuver(
                type: .depart,
                coordinate: coords[0],
                distanceAlongRoute: 0,
                distanceToNext: 400,
                streetName: "Trail",
                instruction: "Head east"
            ),
            Maneuver(
                type: .uTurn,
                coordinate: at(LocalPoint(x: 400, y: 0)),
                distanceAlongRoute: 400,
                distanceToNext: 400,
                streetName: "Trail",
                instruction: "Make a U-turn"
            ),
            Maneuver(
                type: .arrive,
                coordinate: coords.last!,
                distanceAlongRoute: 800,
                distanceToNext: 0,
                streetName: nil,
                instruction: "Arrive at destination"
            ),
        ]

        var tracker = RouteProgressTracker(coordinates: coords, maneuvers: maneuvers)

        // Ride outbound to ~200 m with noise; must stay on outbound leg.
        for x in stride(from: 0.0, through: 200.0, by: 10.0) {
            let fix = location(at: LocalPoint(x: x, y: Double.random(in: -5...5)), accuracy: 5, speed: 4)
            let progress = tracker.update(location: fix)
            XCTAssertLessThan(
                progress.distanceAlongRoute,
                350,
                "Out-and-back matcher jumped ahead to \(progress.distanceAlongRoute) at x=\(x)"
            )
            XCTAssertEqual(progress.nextManeuver?.type, .uTurn)
        }
    }

    func testLollipopLoopStemDoesNotJumpAhead() {
        // 300 m stem out, 400 m square bulb, 300 m stem back on the same geometry.
        var coords: [CLLocationCoordinate2D] = []
        for x in stride(from: 0.0, through: 300.0, by: 10.0) {
            coords.append(at(LocalPoint(x: x, y: 0)))
        }
        for y in stride(from: 10.0, through: 200.0, by: 10.0) {
            coords.append(at(LocalPoint(x: 300, y: y)))
        }
        for x in stride(from: 290.0, through: 100.0, by: -10.0) {
            coords.append(at(LocalPoint(x: x, y: 200)))
        }
        for y in stride(from: 190.0, through: 0.0, by: -10.0) {
            coords.append(at(LocalPoint(x: 100, y: y)))
        }
        for x in stride(from: 110.0, through: 300.0, by: 10.0) {
            coords.append(at(LocalPoint(x: x, y: 0)))
        }
        for x in stride(from: 290.0, through: 0.0, by: -10.0) {
            coords.append(at(LocalPoint(x: x, y: 0)))
        }

        let total = PlannedRoute.polylineLength(coords)
        let stem = 300.0
        let maneuvers = [
            Maneuver(
                type: .depart,
                coordinate: coords[0],
                distanceAlongRoute: 0,
                distanceToNext: stem,
                streetName: "Stem",
                instruction: "Head east"
            ),
            Maneuver(
                type: .continue,
                coordinate: at(LocalPoint(x: 300, y: 0)),
                distanceAlongRoute: stem,
                distanceToNext: max(0, total - 2 * stem),
                streetName: "Via",
                instruction: ManeuverBuilder.passThroughInstruction(streetName: "Via")
            ),
            Maneuver(
                type: .arrive,
                coordinate: coords.last!,
                distanceAlongRoute: total,
                distanceToNext: 0,
                streetName: nil,
                instruction: "Arrive at destination"
            ),
        ]

        var tracker = RouteProgressTracker(coordinates: coords, maneuvers: maneuvers)
        var lastAlong = -1.0

        // Outbound along the stem — must not jump to the return stem.
        for x in stride(from: 0.0, through: 250.0, by: 10.0) {
            let fix = location(at: LocalPoint(x: x, y: Double.random(in: -4...4)), accuracy: 5, speed: 4)
            let progress = tracker.update(location: fix)
            XCTAssertLessThan(
                progress.distanceAlongRoute,
                stem + 40,
                "Lollipop jumped ahead to \(progress.distanceAlongRoute) while still on outbound stem at x=\(x)"
            )
            XCTAssertGreaterThanOrEqual(progress.distanceAlongRoute, lastAlong - 15)
            lastAlong = progress.distanceAlongRoute
        }
    }

    func testLowAccuracyFixDoesNotUpdateMatch() {
        let coords = [at(LocalPoint(x: 0, y: 0)), at(LocalPoint(x: 200, y: 0))]
        var tracker = RouteProgressTracker(coordinates: coords, maneuvers: [])
        let good = location(at: LocalPoint(x: 50, y: 0), accuracy: 5, speed: 3)
        let matched = tracker.update(location: good)
        XCTAssertTrue(matched.didMatch)
        XCTAssertEqual(matched.distanceAlongRoute, 50, accuracy: 5)

        let bad = location(at: LocalPoint(x: 180, y: 0), accuracy: 35, speed: 3)
        let skipped = tracker.update(location: bad)
        XCTAssertFalse(skipped.didMatch)
        XCTAssertEqual(skipped.distanceAlongRoute, matched.distanceAlongRoute, accuracy: 0.1)
    }

    // MARK: - Helpers

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func location(
        at point: LocalPoint,
        accuracy: Double,
        speed: Double,
        timestamp: Date = Date()
    ) -> CLLocation {
        CLLocation(
            coordinate: at(point),
            altitude: 1500,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: 90,
            speed: speed,
            timestamp: timestamp
        )
    }
}
