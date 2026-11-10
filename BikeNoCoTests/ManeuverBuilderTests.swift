import XCTest
import CoreLocation
@testable import BikeNoCo

final class ManeuverBuilderTests: XCTestCase {
    private let originLat = 40.5
    private let originLon = -105.0

    private var projection: LocalProjection {
        LocalProjection(originLatitude: originLat, originLongitude: originLon)
    }

    func testNinetyDegreeTurnAtNameChangeEmitsLeftOrRight() {
        let route = planned(
            edges: [
                edge(from: p(0, 0), to: p(200, 0), name: "First St", length: 200),
                edge(from: p(200, 0), to: p(200, 200), name: "Second St", length: 200)
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let turns = maneuvers.filter { $0.type == .left || $0.type == .right }
        XCTAssertEqual(turns.count, 1, "Expected one turn, got \(maneuvers.map(\.instruction))")
        XCTAssertEqual(turns[0].type, .left)
        XCTAssertTrue(turns[0].instruction.lowercased().contains("left"))
        XCTAssertTrue(turns[0].instruction.contains("Second"))
    }

    func testNamedPolylineWithMidRunNinetyEmitsOneStayOnTurn() {
        // One named run: east 150 m, then south 150 m — 90° right corner mid-run.
        let route = planned(
            edges: [
                edge(
                    geometry: [
                        at(p(0, 0)),
                        at(p(150, 0)),
                        at(p(150, -150))
                    ],
                    name: "Remington St",
                    length: 300
                )
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let turns = maneuvers.filter { $0.type == .left || $0.type == .right }
        XCTAssertEqual(turns.count, 1, "Expected one mid-run turn, got \(maneuvers.map(\.instruction))")
        XCTAssertEqual(turns[0].type, .right)
        XCTAssertTrue(
            turns[0].instruction.lowercased().contains("stay on"),
            "Expected stay-on wording, got \(turns[0].instruction)"
        )
        XCTAssertTrue(turns[0].instruction.contains("Remington"))
    }

    func testEarlyInRunTurnMergesOntoWording() {
        // Name change then a 90° right within 50 m → "Turn right onto Second".
        let route = planned(
            edges: [
                edge(from: p(0, 0), to: p(100, 0), name: "First St", length: 100),
                edge(
                    geometry: [
                        at(p(100, 0)),
                        at(p(140, 0)),
                        at(p(140, -160))
                    ],
                    name: "Second St",
                    length: 200
                )
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let middle = maneuvers.filter { $0.type != .depart && $0.type != .arrive }
        guard let turn = middle.first(where: { $0.type == .left || $0.type == .right }) else {
            XCTFail("Expected a turn onto Second, got \(maneuvers.map(\.instruction))")
            return
        }
        XCTAssertEqual(turn.type, .right)
        XCTAssertTrue(
            turn.instruction.contains("onto Second"),
            "Expected onto wording, got \(turn.instruction)"
        )
        XCTAssertFalse(turn.instruction.lowercased().contains("stay on"))
        XCTAssertFalse(
            middle.contains { $0.type == .continue },
            "Early turn should replace Continue, got \(middle.map(\.instruction))"
        )
    }

    func testLaporteAveAndLaporteNormalizeEqual() {
        XCTAssertEqual(
            NameNormalizer.normalize("LAPORTE AVE"),
            NameNormalizer.normalize("Laporte")
        )
    }

    func testRoundedCurbNinetyDegreeClassifiesAsTurn() {
        // Eastbound approach, 8 m radius quarter-circle, then northbound.
        var geometry: [CLLocationCoordinate2D] = [at(p(0, 0)), at(p(100, 0))]
        let radius = 8.0
        let center = p(100, 8)
        for step in 1...8 {
            let angle = -Double.pi / 2 + (Double.pi / 2) * (Double(step) / 8.0)
            geometry.append(at(LocalPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )))
        }
        geometry.append(at(p(108, 108)))

        let route = planned(
            edges: [
                edge(geometry: Array(geometry.prefix(2)), name: "Approach St", length: 100),
                edge(
                    geometry: Array(geometry.dropFirst()),
                    name: "Exit St",
                    length: polylineLength(Array(geometry.dropFirst()))
                )
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let turns = maneuvers.filter { $0.type == .left || $0.type == .right }
        XCTAssertEqual(turns.count, 1, "Rounded 90° should be a turn, got \(maneuvers.map(\.instruction))")
        XCTAssertEqual(turns[0].type, .left)
        XCTAssertGreaterThan(abs(turns[0].turnAngleDegrees ?? 0), 60)
        XCTAssertLessThan(abs(turns[0].turnAngleDegrees ?? 0), 120)
    }

    func testSkewedSyntheticAttachmentDoesNotChangeCornerClassification() {
        // Same 90° corner, but a 12 m skewed synthetic attachment sits at the joint.
        let approach = edge(from: p(0, 0), to: p(100, 0), name: "Approach St", length: 100)
        let attachment = edge(
            from: p(100, 0),
            to: p(108, 8),
            name: "",
            length: 12,
            isConnector: true,
            osmClass: nil
        )
        let exit = edge(from: p(108, 8), to: p(108, 108), name: "Exit St", length: 100)
        let route = planned(edges: [approach, attachment, exit])
        let maneuvers = ManeuverBuilder.build(from: route)
        let turns = maneuvers.filter { $0.type == .left || $0.type == .right }
        XCTAssertEqual(turns.count, 1, "Expected one turn, got \(maneuvers.map(\.instruction))")
        XCTAssertEqual(turns[0].type, .left)
        XCTAssertGreaterThan(abs(turns[0].turnAngleDegrees ?? 0), 60)
    }

    func testNormalizedNameChangeGoingStraightEmitsNothing() {
        let route = planned(
            edges: [
                edge(from: p(0, 0), to: p(200, 0), name: "W LAUREL ST", length: 200),
                edge(from: p(200, 0), to: p(400, 0), name: "West Laurel Street", length: 200)
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let middle = maneuvers.filter { $0.type != .depart && $0.type != .arrive }
        XCTAssertTrue(middle.isEmpty, "Expected no middle maneuvers, got \(middle.map(\.instruction))")
    }

    func testShortSyntheticAttachmentBetweenSameTrailEmitsNothing() {
        let route = planned(
            edges: [
                edge(from: p(0, 0), to: p(100, 0), name: "Spring Creek Trail", length: 100, facility: .pavedTrail),
                edge(
                    from: p(100, 0),
                    to: p(112, 0),
                    name: "",
                    length: 12,
                    isConnector: true,
                    osmClass: nil
                ),
                edge(from: p(112, 0), to: p(250, 0), name: "Spring Creek Trail", length: 138, facility: .pavedTrail)
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let middle = maneuvers.filter { $0.type != .depart && $0.type != .arrive }
        XCTAssertTrue(middle.isEmpty, "Synthetic seam should be silent, got \(middle.map(\.instruction))")
    }

    func testShortUnnamedConnectorBetweenDifferentStreetsProducesOneManeuver() {
        let route = planned(
            edges: [
                edge(from: p(0, 0), to: p(100, 0), name: "Remington St", length: 100),
                edge(from: p(100, 0), to: p(100, 30), name: "", length: 30, isConnector: true, osmClass: .residential),
                edge(from: p(100, 30), to: p(200, 30), name: "Mason St", length: 100)
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let middle = maneuvers.filter { $0.type != .depart && $0.type != .arrive }
        XCTAssertEqual(middle.count, 1, "Expected one maneuver, got \(middle.map(\.instruction))")
    }

    func testZigzagJitterDoesNotProduceTurns() {
        let route = planned(
            edges: [
                edge(
                    geometry: [
                        at(p(0, 0)),
                        at(p(40, 0)),
                        at(p(42, 3)),
                        at(p(44, -2)),
                        at(p(80, 0)),
                        at(p(120, 1)),
                        at(p(160, 0))
                    ],
                    name: "Jitter Ave",
                    length: 160
                )
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let middle = maneuvers.filter { $0.type != .depart && $0.type != .arrive }
        XCTAssertTrue(middle.isEmpty, "Jitter should not create turns, got \(middle.map(\.instruction))")
    }

    func testDepartAndArriveAlwaysPresentAndDistancesSum() {
        let route = planned(
            edges: [
                edge(from: p(0, 0), to: p(100, 0), name: "A St", length: 100),
                edge(from: p(100, 0), to: p(100, 100), name: "B St", length: 100)
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        XCTAssertEqual(maneuvers.first?.type, .depart)
        XCTAssertEqual(maneuvers.last?.type, .arrive)
        XCTAssertTrue(maneuvers.first?.instruction.hasPrefix("Head ") == true)
        let sum = maneuvers.dropLast().reduce(0.0) { $0 + $1.distanceToNext }
        XCTAssertEqual(sum, route.totalDistanceMeters, accuracy: 1.0)
        XCTAssertEqual(maneuvers.last?.distanceAlongRoute ?? -1, route.totalDistanceMeters, accuracy: 1.0)
    }

    func testLaportePathHopAbsorbedByABA() {
        // Laporte — short path hop — Laporte, continuing roughly east.
        let route = planned(
            edges: [
                edge(from: p(0, 0), to: p(200, 0), name: "Laporte", length: 200),
                edge(
                    from: p(200, 0),
                    to: p(220, 20),
                    name: "",
                    length: 28,
                    facility: .pavedTrail,
                    isConnector: true,
                    osmClass: .path
                ),
                edge(from: p(220, 20), to: p(420, 20), name: "Laporte", length: 200)
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let middle = maneuvers.filter { $0.type != .depart && $0.type != .arrive }
        XCTAssertTrue(middle.isEmpty, "Laporte path hop should absorb, got \(middle.map(\.instruction))")
    }

    func testFourRunWeaveAbsorbedIteratively() {
        // Magnolia / City Park / Magnolia / City Park weave that nets roughly straight.
        let route = planned(
            edges: [
                edge(from: p(0, 0), to: p(200, 0), name: "Magnolia", length: 200),
                edge(from: p(200, 0), to: p(220, 40), name: "City Park", length: 45),
                edge(from: p(220, 40), to: p(420, 40), name: "Magnolia", length: 200),
                edge(from: p(420, 40), to: p(440, 80), name: "City Park", length: 45),
                edge(from: p(440, 80), to: p(640, 80), name: "Magnolia", length: 200)
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        let middle = maneuvers.filter { $0.type != .depart && $0.type != .arrive }
        XCTAssertTrue(middle.isEmpty, "Four-run weave should collapse, got \(middle.map(\.instruction))")
    }

    func testDepartUsesNamedRunWithinSixtyMeters() {
        let route = planned(
            edges: [
                edge(from: p(0, 0), to: p(30, 0), name: "", length: 30, isConnector: true, osmClass: .residential),
                edge(from: p(30, 0), to: p(230, 0), name: "Remington St", length: 200)
            ]
        )
        let maneuvers = ManeuverBuilder.build(from: route)
        XCTAssertEqual(maneuvers.first?.type, .depart)
        XCTAssertTrue(
            maneuvers.first?.instruction.contains("Remington") == true,
            "Depart should name Remington, got \(maneuvers.first?.instruction ?? "")"
        )
        XCTAssertTrue(maneuvers.first?.instruction.hasPrefix("Head ") == true)
    }

    func testNameNormalizerUnifiesArcGISAndOSM() {
        XCTAssertEqual(
            NameNormalizer.normalize("W LAUREL ST"),
            NameNormalizer.normalize("West Laurel Street")
        )
        XCTAssertEqual(NameNormalizer.displayName("W LAUREL ST"), "W Laurel St")
    }

    // MARK: - Helpers

    private func p(_ x: Double, _ y: Double) -> LocalPoint {
        LocalPoint(x: x, y: y)
    }

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func polylineLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count >= 2 else { return 0 }
        var total = 0.0
        let locals = coords.map { projection.toLocal($0) }
        for i in 1..<locals.count {
            total += locals[i - 1].distance(to: locals[i])
        }
        return total
    }

    private func edge(
        from: LocalPoint,
        to: LocalPoint,
        name: String,
        length: Double,
        facility: FacilityType = .bikeLane,
        isConnector: Bool = false,
        osmClass: OSMHighwayClass? = nil
    ) -> GraphEdge {
        edge(
            geometry: [at(from), at(to)],
            name: name,
            length: length,
            facility: facility,
            isConnector: isConnector,
            osmClass: osmClass
        )
    }

    private func edge(
        geometry: [CLLocationCoordinate2D],
        name: String,
        length: Double,
        facility: FacilityType = .bikeLane,
        isConnector: Bool = false,
        osmClass: OSMHighwayClass? = nil
    ) -> GraphEdge {
        GraphEdge(
            id: Int.random(in: 1...1_000_000),
            fromID: 0,
            toID: 1,
            lengthMeters: length,
            geometry: geometry,
            facilityType: facility,
            lts: 1,
            name: name,
            sourceRouteID: UUID(),
            isConnector: isConnector,
            osmClass: osmClass
        )
    }

    private func planned(edges: [GraphEdge]) -> PlannedRoute {
        var coords: [CLLocationCoordinate2D] = []
        for edge in edges {
            if coords.isEmpty {
                coords.append(contentsOf: edge.geometry)
            } else {
                coords.append(contentsOf: edge.geometry.dropFirst())
            }
        }
        return PlannedRoute.make(
            edges: edges,
            coordinates: coords,
            origin: coords.first ?? at(p(0, 0)),
            destination: coords.last ?? at(p(0, 0))
        )
    }
}
