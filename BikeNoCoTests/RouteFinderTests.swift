import XCTest
import CoreLocation
@testable import BikeNoCo

final class RouteFinderTests: XCTestCase {
    private let config = BikeNetworkGraphBuilder.Config(
        endpointSnapMeters: 8,
        gapSearchMeters: 25,
        originLatitude: 40.5,
        originLongitude: -105.0
    )

    private var projection: LocalProjection {
        LocalProjection(originLatitude: config.originLatitude, originLongitude: config.originLongitude)
    }

    func testPrefersLongerTrailOverShorterSharrow() {
        // Shared corridor from x=0 to a fork at x=100, then two alternatives to x=1100/1300.
        let approach = route(
            points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 100, y: 0)],
            facility: .bikeLane,
            name: "Approach",
            lts: 2
        )
        let trail = route(
            points: [LocalPoint(x: 100, y: 0), LocalPoint(x: 1300, y: 0)],
            facility: .pavedTrail,
            name: "Trail",
            lts: nil
        )
        let sharrow = route(
            points: [LocalPoint(x: 100, y: 5), LocalPoint(x: 1100, y: 5)],
            facility: .sharrow,
            name: "Sharrow",
            lts: 3
        )
        let finishTrail = route(
            points: [LocalPoint(x: 1300, y: 0), LocalPoint(x: 1300, y: 50)],
            facility: .bikeLane,
            name: "Finish",
            lts: 2
        )
        let finishSharrow = route(
            points: [LocalPoint(x: 1100, y: 5), LocalPoint(x: 1300, y: 50)],
            facility: .bikeLane,
            name: "Finish Link",
            lts: 2
        )

        let graph = BikeNetworkGraphBuilder.build(
            from: [approach, trail, sharrow, finishTrail, finishSharrow],
            config: config
        )
        let origin = at(LocalPoint(x: 0, y: 0))
        let destination = at(LocalPoint(x: 1300, y: 50))

        let result = RouteFinder.route(from: origin, to: destination, graph: graph)
        guard case .success(let planned) = result else {
            return XCTFail("Expected a route, got \(result)")
        }

        let usedTrail = planned.edges.contains { $0.facilityType == .pavedTrail }
        let usedSharrow = planned.edges.contains { $0.facilityType == .sharrow }
        XCTAssertTrue(usedTrail, "Default multipliers should prefer the 1.2 km trail")
        XCTAssertFalse(usedSharrow, "Should not take the 1.0 km sharrow when a trail exists")
        XCTAssertGreaterThan(planned.totalDistanceMeters, 1200)
    }

    func testMaxLTSAvoidsHighStressShortcutAndFailsWhenOnlyOption() {
        let safe = route(
            points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 100, y: 0), LocalPoint(x: 100, y: 200), LocalPoint(x: 200, y: 200)],
            facility: .bikeLane,
            name: "Safe",
            lts: 2
        )
        let shortcut = route(
            points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 200, y: 200)],
            facility: .bikeLane,
            name: "Shortcut",
            lts: 4
        )
        let graph = BikeNetworkGraphBuilder.build(from: [safe, shortcut], config: config)
        let origin = at(LocalPoint(x: 0, y: 0))
        let destination = at(LocalPoint(x: 200, y: 200))

        var profile = RoutingProfile.default
        profile.maxLTS = 2

        let result = RouteFinder.route(from: origin, to: destination, graph: graph, profile: profile)
        guard case .success(let planned) = result else {
            return XCTFail("Expected low-stress detour, got \(result)")
        }
        XCTAssertFalse(planned.edges.contains { $0.lts == 4 })
        XCTAssertGreaterThan(planned.totalDistanceMeters, 250)

        let onlyHigh = BikeNetworkGraphBuilder.build(from: [shortcut], config: config)
        let blocked = RouteFinder.route(from: origin, to: destination, graph: onlyHigh, profile: profile)
        guard case .failure(let error) = blocked else {
            return XCTFail("Expected noPath when only LTS 4 remains")
        }
        if case .noPath = error {
            // expected
        } else {
            XCTFail("Expected noPath, got \(error)")
        }
    }

    func testSnappingToMiddleOfEdgeUsesPartialDistances() {
        let segment = route(
            points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 1000, y: 0)],
            facility: .bikeLane,
            name: "Long",
            lts: 2
        )
        let graph = BikeNetworkGraphBuilder.build(from: [segment], config: config)
        let origin = at(LocalPoint(x: 250, y: 5))
        let destination = at(LocalPoint(x: 750, y: -5))

        let result = RouteFinder.route(from: origin, to: destination, graph: graph)
        guard case .success(let planned) = result else {
            return XCTFail("Expected route, got \(result)")
        }

        XCTAssertEqual(planned.totalDistanceMeters, 500, accuracy: 15)
        XCTAssertFalse(planned.coordinates.isEmpty)
    }

    func testOriginAndDestinationBeyondSnapDistanceReturnErrors() {
        let segment = route(
            points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 100, y: 0)],
            facility: .bikeLane,
            name: "Short",
            lts: 2
        )
        let graph = BikeNetworkGraphBuilder.build(from: [segment], config: config)

        // Default maxSnapMeters is 300; place queries clearly beyond that.
        let farOrigin = at(LocalPoint(x: 0, y: 400))
        let nearDest = at(LocalPoint(x: 100, y: 0))
        let originResult = RouteFinder.route(from: farOrigin, to: nearDest, graph: graph)
        XCTAssertEqual(originResult, .failure(.originTooFar))

        let nearOrigin = at(LocalPoint(x: 0, y: 0))
        let farDest = at(LocalPoint(x: 100, y: 400))
        let destResult = RouteFinder.route(from: nearOrigin, to: farDest, graph: graph)
        XCTAssertEqual(destResult, .failure(.destinationTooFar))
    }

    func testDisconnectedComponentsReturnNoPath() {
        let a = route(
            points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 100, y: 0)],
            facility: .bikeLane,
            name: "A",
            lts: 2
        )
        let b = route(
            points: [LocalPoint(x: 500, y: 0), LocalPoint(x: 600, y: 0)],
            facility: .bikeLane,
            name: "B",
            lts: 2
        )
        let graph = BikeNetworkGraphBuilder.build(from: [a, b], config: config)
        let result = RouteFinder.route(
            from: at(LocalPoint(x: 0, y: 0)),
            to: at(LocalPoint(x: 600, y: 0)),
            graph: graph
        )
        guard case .failure(let error) = result else {
            return XCTFail("Expected noPath across components")
        }
        guard case .noPath(let hint) = error else {
            return XCTFail("Expected noPath, got \(error)")
        }
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("disconnected") == true)
    }

    // MARK: - Helpers

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func route(
        points: [LocalPoint],
        facility: FacilityType,
        name: String,
        lts: Int?
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
