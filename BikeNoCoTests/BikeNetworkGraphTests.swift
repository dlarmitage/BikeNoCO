import XCTest
import CoreLocation
@testable import BikeNoCo

final class BikeNetworkGraphTests: XCTestCase {
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

    func testEndpointsFiveMetersApartJoinIntoOneComponent() {
        let routes = [
            route(from: LocalPoint(x: 0, y: 0), to: LocalPoint(x: 100, y: 0)),
            route(from: LocalPoint(x: 105, y: 0), to: LocalPoint(x: 200, y: 0))
        ]
        let graph = BikeNetworkGraphBuilder.build(from: routes, config: config)
        let report = ConnectivityReport.make(from: graph, gapSearchMeters: config.gapSearchMeters)

        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertEqual(report.componentCount, 1)
        XCTAssertTrue(report.gapCandidates.isEmpty)
    }

    func testEndpointsFifteenMetersApartStaySeparateAndAreAGap() {
        let routes = [
            route(from: LocalPoint(x: 0, y: 0), to: LocalPoint(x: 100, y: 0)),
            route(from: LocalPoint(x: 115, y: 0), to: LocalPoint(x: 200, y: 0))
        ]
        let graph = BikeNetworkGraphBuilder.build(from: routes, config: config)
        let report = ConnectivityReport.make(from: graph, gapSearchMeters: config.gapSearchMeters)

        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertEqual(report.componentCount, 2)
        XCTAssertEqual(report.gapCandidates.count, 1, "symmetric A→B / B→A pairs should dedupe")
        let closest = report.gapCandidates[0].distanceMeters
        XCTAssertEqual(closest, 15, accuracy: 0.5)
    }

    func testParallelSegmentTenMetersAwayIsNotJoined() {
        // Parallel along its length at 10 m. Endpoints are inset so endpoint clustering
        // (12 m) does not join the corners; t-junction snap (8 m) must not stitch the sides.
        let through = route(from: LocalPoint(x: 0, y: 0), to: LocalPoint(x: 200, y: 0))
        let parallel = route(from: LocalPoint(x: 50, y: 10), to: LocalPoint(x: 150, y: 10))
        let graph = BikeNetworkGraphBuilder.build(from: [through, parallel], config: config)
        let report = ConnectivityReport.make(from: graph, gapSearchMeters: config.gapSearchMeters)

        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertEqual(report.componentCount, 2)
        XCTAssertEqual(graph.nodes.count, 4)
    }

    func testTJunctionSplitsIntoThreeEdgesAndOneComponent() {
        let through = route(from: LocalPoint(x: 0, y: 0), to: LocalPoint(x: 100, y: 0))
        let stub = route(from: LocalPoint(x: 50, y: 4), to: LocalPoint(x: 50, y: 50))
        let graph = BikeNetworkGraphBuilder.build(from: [through, stub], config: config)
        let report = ConnectivityReport.make(from: graph, gapSearchMeters: config.gapSearchMeters)

        XCTAssertEqual(graph.edges.count, 3)
        XCTAssertEqual(report.componentCount, 1)
        XCTAssertEqual(graph.nodes.count, 4)
    }

    func testXCrossingIsNotJoinedAndCountsAsOneCrossing() {
        let a = route(from: LocalPoint(x: 0, y: 0), to: LocalPoint(x: 100, y: 100))
        let b = route(from: LocalPoint(x: 0, y: 100), to: LocalPoint(x: 100, y: 0))
        let graph = BikeNetworkGraphBuilder.build(from: [a, b], config: config)
        let report = ConnectivityReport.make(from: graph, gapSearchMeters: config.gapSearchMeters)

        XCTAssertEqual(graph.edges.count, 2)
        XCTAssertEqual(report.componentCount, 2)
        XCTAssertEqual(report.crossingCount, 1)
    }

    func testRecommendedRideRoutesAreExcluded() {
        let infrastructure = route(
            from: LocalPoint(x: 0, y: 0),
            to: LocalPoint(x: 100, y: 0),
            facility: .bikeLane
        )
        let overlay = route(
            from: LocalPoint(x: 0, y: 50),
            to: LocalPoint(x: 100, y: 50),
            facility: .recommendedRide
        )
        let graph = BikeNetworkGraphBuilder.build(from: [infrastructure, overlay], config: config)

        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges.first?.facilityType, .bikeLane)
        XCTAssertFalse(graph.edges.contains { $0.facilityType == .recommendedRide })
    }

    func testEdgeLengthWithinOnePercentOfHandComputed() {
        let path = [
            LocalPoint(x: 0, y: 0),
            LocalPoint(x: 100, y: 0),
            LocalPoint(x: 100, y: 50)
        ]
        let graph = BikeNetworkGraphBuilder.build(from: [route(points: path)], config: config)

        XCTAssertEqual(graph.edges.count, 1)
        let length = graph.edges[0].lengthMeters
        XCTAssertEqual(length, 150, accuracy: 1.5)
    }

    // MARK: - Helpers

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func route(
        from: LocalPoint,
        to: LocalPoint,
        facility: FacilityType = .bikeLane
    ) -> BikeRoute {
        route(points: [from, to], facility: facility)
    }

    private func route(points: [LocalPoint], facility: FacilityType = .bikeLane) -> BikeRoute {
        BikeRoute(
            id: UUID(),
            objectId: 1,
            streetName: "Test Street",
            facilityType: facility,
            lts: 2,
            mapSymbolClass: nil,
            bikewayName: nil,
            speedLimit: nil,
            paths: [points.map { at($0) }]
        )
    }
}
