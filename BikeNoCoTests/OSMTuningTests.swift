import XCTest
import CoreLocation
@testable import BikeNoCo

final class OSMTuningTests: XCTestCase {
    private let config = BikeNetworkGraphBuilder.Config(
        endpointSnapMeters: 12,
        tJunctionSnapMeters: 8,
        originLatitude: 40.5,
        originLongitude: -105.0
    )

    private var projection: LocalProjection {
        LocalProjection(originLatitude: config.originLatitude, originLongitude: config.originLongitude)
    }

    func testPruningRemovesOSMOnlyIslandButKeepsArcGISIsland() {
        let arcgisIsland = route(points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 50, y: 0)], facility: .bikeLane)
        let graph = BikeNetworkGraphBuilder.build(from: [arcgisIsland], config: config)

        let attachedOSM = connector(
            from: LocalPoint(x: 0, y: 8),
            to: LocalPoint(x: 0, y: 80),
            highway: .residential,
            osmStart: 1,
            osmEnd: 2
        )
        let orphanOSM = connector(
            from: LocalPoint(x: 1000, y: 1000),
            to: LocalPoint(x: 1100, y: 1000),
            highway: .residential,
            osmStart: 10,
            osmEnd: 11
        )

        let merged = OSMConnectorMerger.merge(arcgis: graph, connectors: [attachedOSM, orphanOSM])
        XCTAssertEqual(merged.componentsAfterPrune, 1)
        XCTAssertGreaterThan(merged.largestComponentShareAfterPrune, 0.99)

        let osmOnlyFar = merged.graph.edges.filter {
            $0.isConnector && $0.osmClass == .residential && ($0.geometry.first.map { projection.toLocal($0).x } ?? 0) > 500
        }
        XCTAssertTrue(osmOnlyFar.isEmpty, "OSM-only orphan island should be pruned")
        XCTAssertTrue(merged.graph.edges.contains { !$0.isConnector })
    }

    func testCacheRoundTripYieldsIdenticalRoute() throws {
        let routes = [
            route(points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 100, y: 0)], facility: .bikeLane, objectId: 1, layer: "test"),
            route(points: [LocalPoint(x: 100, y: 0), LocalPoint(x: 100, y: 100)], facility: .pavedTrail, objectId: 2, layer: "test")
        ]
        let connectors = [
            connector(from: LocalPoint(x: 0, y: 10), to: LocalPoint(x: 0, y: 80), highway: .residential, osmStart: 1, osmEnd: 2)
        ]
        let built = BikeNetworkGraphBuilder.build(from: routes, connectors: connectors, config: config)
        let key = GraphCache.makeKey(routes: routes, osmTimestamp: "test-ts")
        let payload = GraphCache.encode(graph: built.graph, key: key, osmTimestamp: "test-ts")
        let restored = GraphCache.decodeGraph(payload)

        let origin = at(LocalPoint(x: 0, y: 0))
        let destination = at(LocalPoint(x: 100, y: 100))
        let a = RouteFinder.route(from: origin, to: destination, graph: built.graph)
        let b = RouteFinder.route(from: origin, to: destination, graph: restored)
        guard case .success(let ra) = a, case .success(let rb) = b else {
            return XCTFail("Expected both routes to succeed: \(a) \(b)")
        }
        XCTAssertEqual(ra.totalDistanceMeters, rb.totalDistanceMeters, accuracy: 0.5)
        XCTAssertEqual(ra.edges.count, rb.edges.count)
        XCTAssertEqual(ra.lowStressShare, rb.lowStressShare, accuracy: 0.001)
    }

    func testCacheKeyStableAcrossFreshUUIDs() {
        let a = [
            route(points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 10, y: 0)], facility: .bikeLane, objectId: 42, layer: "fc"),
            route(points: [LocalPoint(x: 10, y: 0), LocalPoint(x: 20, y: 0)], facility: .pavedTrail, objectId: 7, layer: "fc")
        ]
        let b = [
            route(points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 10, y: 0)], facility: .bikeLane, objectId: 42, layer: "fc"),
            route(points: [LocalPoint(x: 10, y: 0), LocalPoint(x: 20, y: 0)], facility: .pavedTrail, objectId: 7, layer: "fc")
        ]
        XCTAssertNotEqual(a[0].id, b[0].id)
        XCTAssertEqual(
            GraphCache.makeKey(routes: a, osmTimestamp: "ts1"),
            GraphCache.makeKey(routes: b, osmTimestamp: "ts1")
        )
        XCTAssertNotEqual(
            GraphCache.makeKey(routes: a, osmTimestamp: "ts1"),
            GraphCache.makeKey(routes: a, osmTimestamp: "ts2")
        )
    }

    func testIsLowStressRules() {
        let trail = edge(facility: .pavedTrail, lts: nil, connector: false, osm: nil)
        let lts2 = edge(facility: .bikeLane, lts: 2, connector: false, osm: nil)
        let lts4 = edge(facility: .bikeLane, lts: 4, connector: false, osm: nil)
        let sharrowNil = edge(facility: .sharrow, lts: nil, connector: false, osm: nil)
        let residential = edge(facility: .unclassified, lts: nil, connector: true, osm: .residential)
        let primary = edge(facility: .unclassified, lts: nil, connector: true, osm: .primary)
        let cycleway = edge(facility: .unclassified, lts: nil, connector: true, osm: .cycleway)
        let synthetic = edge(facility: .unclassified, lts: nil, connector: true, osm: nil)

        XCTAssertTrue(RoutingProfile.isLowStress(trail))
        XCTAssertTrue(RoutingProfile.isLowStress(lts2))
        XCTAssertFalse(RoutingProfile.isLowStress(lts4))
        XCTAssertFalse(RoutingProfile.isLowStress(sharrowNil))
        XCTAssertTrue(RoutingProfile.isLowStress(residential))
        XCTAssertFalse(RoutingProfile.isLowStress(primary))
        XCTAssertTrue(RoutingProfile.isLowStress(cycleway))
        XCTAssertTrue(RoutingProfile.isLowStress(synthetic))
    }

    // MARK: - Helpers

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func route(
        points: [LocalPoint],
        facility: FacilityType,
        objectId: Int = 1,
        layer: String = "test"
    ) -> BikeRoute {
        BikeRoute(
            id: UUID(),
            objectId: objectId,
            streetName: "Street",
            facilityType: facility,
            lts: 2,
            mapSymbolClass: nil,
            bikewayName: nil,
            speedLimit: nil,
            paths: [points.map { at($0) }],
            sourceLayer: layer
        )
    }

    private func connector(
        from: LocalPoint,
        to: LocalPoint,
        highway: OSMHighwayClass,
        osmStart: Int64,
        osmEnd: Int64
    ) -> OSMConnectorEdge {
        OSMConnectorEdge(
            highwayClass: highway,
            name: nil,
            isBridge: false,
            isTunnel: false,
            startNodeID: osmStart,
            endNodeID: osmEnd,
            coordinates: [at(from), at(to)]
        )
    }

    private func edge(
        facility: FacilityType,
        lts: Int?,
        connector: Bool,
        osm: OSMHighwayClass?
    ) -> GraphEdge {
        GraphEdge(
            id: 1,
            fromID: 0,
            toID: 1,
            lengthMeters: 10,
            geometry: [at(LocalPoint(x: 0, y: 0)), at(LocalPoint(x: 10, y: 0))],
            facilityType: facility,
            lts: lts,
            name: "x",
            sourceRouteID: UUID(),
            isConnector: connector,
            osmClass: osm
        )
    }
}
