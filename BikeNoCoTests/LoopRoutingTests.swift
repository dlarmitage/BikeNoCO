import XCTest
import CoreLocation
@testable import BikeNoCo

final class LoopRoutingTests: XCTestCase {
    private let config = BikeNetworkGraphBuilder.Config(
        endpointSnapMeters: 8,
        gapSearchMeters: 25,
        originLatitude: 40.5,
        originLongitude: -105.0
    )

    private var projection: LocalProjection {
        LocalProjection(originLatitude: config.originLatitude, originLongitude: config.originLongitude)
    }

    func testSquareGridLoopUsesOppositeSidesWithNearZeroOverlap() {
        // Square A(0,0)–B(400,0)–C(400,400)–D(0,400).
        let bottom = route(points: [p(0, 0), p(400, 0)], name: "Bottom")
        let right = route(points: [p(400, 0), p(400, 400)], name: "Right")
        let top = route(points: [p(400, 400), p(0, 400)], name: "Top")
        let left = route(points: [p(0, 400), p(0, 0)], name: "Left")
        let graph = BikeNetworkGraphBuilder.build(
            from: [bottom, right, top, left],
            config: config
        )

        let origin = at(p(0, 0))
        let via = at(p(400, 0))
        let result = RouteFinder.loop(from: origin, via: via, graph: graph)
        guard case .success(let looped) = result else {
            return XCTFail("Expected loop, got \(result)")
        }

        XCTAssertEqual(looped.tripShape, .loop)
        XCTAssertEqual(looped.legs.count, 2)
        XCTAssertNotNil(looped.overlapShare)
        XCTAssertLessThan(looped.overlapShare ?? 1, 0.15, "Opposite-side return should barely overlap")

        let returnNames = Set(
            looped.edges
                .suffix(from: looped.outboundEdgeCount ?? 0)
                .map(\.name)
        )
        XCTAssertFalse(returnNames.contains("Bottom"), "Return should not reverse the outbound bottom edge")
        XCTAssertTrue(returnNames.contains("Right") || returnNames.contains("Top") || returnNames.contains("Left"))

        let maneuvers = ManeuverBuilder.build(from: looped)
        let passThrough = maneuvers.first {
            $0.instruction.hasPrefix("Passing your turnaround point")
        }
        XCTAssertNotNil(passThrough)
        XCTAssertEqual(passThrough?.type, .continue)
        XCTAssertEqual(maneuvers.last?.type, .arrive)
        XCTAssertEqual(
            maneuvers.last?.coordinate.latitude ?? 0,
            origin.latitude,
            accuracy: 1e-6
        )
    }

    func testSingleBridgeLoopSucceedsWithBridgeOverlapOnly() {
        // Two banks linked by one bridge. North alternatives sit >40 m off the south
        // corridor so only the bridge is treated as overlapping outbound geometry.
        let leftSouth = route(points: [p(0, 0), p(200, 0)], name: "Left South")
        let leftNorth = route(points: [p(0, 120), p(200, 120)], name: "Left North")
        let leftWest = route(points: [p(0, 0), p(0, 120)], name: "Left West")
        let leftEast = route(points: [p(200, 0), p(200, 120)], name: "Left East")
        let bridge = route(points: [p(200, 0), p(400, 0)], name: "Bridge")
        let rightSouth = route(points: [p(400, 0), p(600, 0)], name: "Right South")
        let rightNorth = route(points: [p(400, 120), p(600, 120)], name: "Right North")
        let rightWest = route(points: [p(400, 0), p(400, 120)], name: "Right West")
        let rightEast = route(points: [p(600, 0), p(600, 120)], name: "Right East")

        let graph = BikeNetworkGraphBuilder.build(
            from: [
                leftSouth, leftNorth, leftWest, leftEast,
                bridge,
                rightSouth, rightNorth, rightWest, rightEast
            ],
            config: config
        )

        let origin = at(p(0, 0))
        let via = at(p(600, 0))
        let result = RouteFinder.loop(from: origin, via: via, graph: graph)
        guard case .success(let looped) = result else {
            return XCTFail("Expected loop across bridge, got \(result)")
        }

        XCTAssertEqual(looped.tripShape, .loop)
        let returnEdges = Array(looped.edges.suffix(from: looped.outboundEdgeCount ?? 0))
        XCTAssertTrue(returnEdges.contains { $0.name == "Bridge" }, "Return must reuse the only bridge")

        let bridgeLength = returnEdges.filter { $0.name == "Bridge" }.reduce(0.0) { $0 + $1.lengthMeters }
        let returnLength = returnEdges.reduce(0.0) { $0 + $1.lengthMeters }
        XCTAssertGreaterThan(returnLength, 0)
        let expectedOverlap = bridgeLength / returnLength
        XCTAssertEqual(looped.overlapShare ?? -1, expectedOverlap, accuracy: 0.08)
        XCTAssertLessThan(looped.overlapShare ?? 1, 0.45, "Only the shared bridge should count as overlap")
        XCTAssertGreaterThan(looped.overlapShare ?? 0, 0.10)
    }

    func testParallelStreetWithin40mIsPenalizedInFavorOfDistantAlternate() {
        // Outbound trail on y=0. Near parallel at y=15 (penalized ×2). Far alternate at y=200.
        let trail = route(points: [p(0, 0), p(1000, 0)], name: "Trail", facility: .pavedTrail)
        let near = route(points: [p(0, 15), p(1000, 15)], name: "Near Parallel", facility: .bikeLane)
        let far = route(points: [p(0, 200), p(1000, 200)], name: "Far Alternate", facility: .bikeLane)
        let westNear = route(points: [p(0, 0), p(0, 15)], name: "West Near")
        let eastNear = route(points: [p(1000, 0), p(1000, 15)], name: "East Near")
        let westFar = route(points: [p(0, 0), p(0, 200)], name: "West Far")
        let eastFar = route(points: [p(1000, 0), p(1000, 200)], name: "East Far")

        let graph = BikeNetworkGraphBuilder.build(
            from: [trail, near, far, westNear, eastNear, westFar, eastFar],
            config: config
        )

        let origin = at(p(0, 0))
        let via = at(p(1000, 0))
        let result = RouteFinder.loop(from: origin, via: via, graph: graph)
        guard case .success(let looped) = result else {
            return XCTFail("Expected loop, got \(result)")
        }

        let returnNames = Set(
            looped.edges
                .suffix(from: looped.outboundEdgeCount ?? 0)
                .map(\.name)
        )
        XCTAssertTrue(returnNames.contains("Far Alternate"), "Distant alternate should win over 15 m parallel")
        XCTAssertFalse(returnNames.contains("Near Parallel"))
        XCTAssertFalse(returnNames.contains("Trail"), "Should not reverse the outbound trail")
        XCTAssertLessThan(looped.overlapShare ?? 1, 0.25)
    }

    func testOutAndBackRegressionStillIdenticalAfterLoopRefactor() {
        let bottom = route(points: [p(0, 0), p(300, 0)], name: "Out")
        let graph = BikeNetworkGraphBuilder.build(from: [bottom], config: config)
        let origin = at(p(0, 0))
        let via = at(p(300, 0))

        guard case .success(let oneWay) = RouteFinder.route(from: origin, to: via, graph: graph) else {
            return XCTFail("Expected one-way")
        }
        let outAndBack = oneWay.asOutAndBack()
        XCTAssertEqual(outAndBack.tripShape, .outAndBack)
        XCTAssertEqual(outAndBack.totalDistanceMeters, oneWay.totalDistanceMeters * 2, accuracy: 1)
        XCTAssertNil(outAndBack.overlapShare)
        XCTAssertEqual(outAndBack.legs.count, 2)

        let maneuvers = ManeuverBuilder.build(from: outAndBack)
        XCTAssertEqual(
            maneuvers.filter { $0.instruction == ManeuverBuilder.outAndBackTurnaroundInstruction }.count,
            1
        )
    }

    // MARK: - Helpers

    private func p(_ x: Double, _ y: Double) -> LocalPoint {
        LocalPoint(x: x, y: y)
    }

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func route(
        points: [LocalPoint],
        name: String,
        facility: FacilityType = .bikeLane,
        lts: Int? = 2
    ) -> BikeRoute {
        BikeRoute(
            id: UUID(),
            objectId: Int.random(in: 1...10_000),
            streetName: name,
            facilityType: facility,
            lts: lts,
            mapSymbolClass: nil,
            bikewayName: name,
            speedLimit: nil,
            paths: [points.map { at($0) }]
        )
    }
}
