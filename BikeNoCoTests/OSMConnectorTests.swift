import XCTest
import CoreLocation
@testable import BikeNoCo

final class OSMConnectorTests: XCTestCase {
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

    func testConflationDropsNearbyParallelOSMEdgeButKeepsFarOne() {
        let arcgis = route(points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 200, y: 0)], facility: .bikeLane)
        let graph = BikeNetworkGraphBuilder.build(from: [arcgis], config: config)

        let near = connector(
            from: LocalPoint(x: 0, y: 6),
            to: LocalPoint(x: 200, y: 6),
            highway: .residential,
            osmStart: 1,
            osmEnd: 2
        )
        let far = connector(
            from: LocalPoint(x: 0, y: 30),
            to: LocalPoint(x: 200, y: 30),
            highway: .residential,
            osmStart: 3,
            osmEnd: 4
        )

        let merged = OSMConnectorMerger.merge(arcgis: graph, connectors: [near, far])
        XCTAssertEqual(merged.osmEdgesLoaded, 2)
        XCTAssertEqual(merged.osmEdgesKept, 1)

        let keptOSM = merged.graph.edges.filter { $0.isConnector && $0.osmClass != nil }
        XCTAssertEqual(keptOSM.count, 1)
        let midY = keptOSM[0].geometry.map { projection.toLocal($0).y }.reduce(0, +) / Double(keptOSM[0].geometry.count)
        XCTAssertEqual(midY, 30, accuracy: 2)
    }

    func testAttachmentWithinFifteenMetersButNotTwenty() {
        let arcgis = route(points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 100, y: 0)], facility: .bikeLane)
        let graph = BikeNetworkGraphBuilder.build(from: [arcgis], config: config)

        // Vertical spur so only the endpoint is near ArcGIS (avoids conflation).
        let close = connector(
            from: LocalPoint(x: 0, y: 10),
            to: LocalPoint(x: 0, y: 120),
            highway: .residential,
            osmStart: 10,
            osmEnd: 11
        )
        let closeMerged = OSMConnectorMerger.merge(arcgis: graph, connectors: [close])
        XCTAssertGreaterThan(closeMerged.attachmentEdgeCount, 0)

        let far = connector(
            from: LocalPoint(x: 0, y: 20),
            to: LocalPoint(x: 0, y: 120),
            highway: .residential,
            osmStart: 20,
            osmEnd: 21
        )
        let farMerged = OSMConnectorMerger.merge(arcgis: graph, connectors: [far])
        XCTAssertEqual(farMerged.attachmentEdgeCount, 0)
    }

    func testAttachmentSkipsBridgeOnlyOSMNode() {
        let arcgis = route(points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 100, y: 0)], facility: .bikeLane)
        let graph = BikeNetworkGraphBuilder.build(from: [arcgis], config: config)

        let bridge = connector(
            from: LocalPoint(x: 0, y: 8),
            to: LocalPoint(x: 0, y: 120),
            highway: .secondary,
            osmStart: 30,
            osmEnd: 31,
            isBridge: true
        )
        let merged = OSMConnectorMerger.merge(arcgis: graph, connectors: [bridge])
        XCTAssertEqual(merged.osmEdgesKept, 1)
        XCTAssertEqual(merged.attachmentEdgeCount, 0)
    }

    func testXCrossingJoinsWithAtGradeJunctionButNotBridge() {
        let a = route(points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 100, y: 100)], facility: .bikeLane)
        let b = route(points: [LocalPoint(x: 0, y: 100), LocalPoint(x: 100, y: 0)], facility: .bikeLane)
        let graph = BikeNetworkGraphBuilder.build(from: [a, b], config: config)
        let before = ConnectivityReport.make(from: graph)
        XCTAssertEqual(before.crossingCount, 1)
        XCTAssertEqual(before.componentCount, 2)

        // Degree-3 at-grade junction near the crossing at (50,50).
        let j1 = connector(from: LocalPoint(x: 50, y: 50), to: LocalPoint(x: 50, y: 120), highway: .residential, osmStart: 100, osmEnd: 101)
        let j2 = connector(from: LocalPoint(x: 50, y: 50), to: LocalPoint(x: 0, y: 50), highway: .residential, osmStart: 100, osmEnd: 102)
        let j3 = connector(from: LocalPoint(x: 50, y: 50), to: LocalPoint(x: 100, y: 50), highway: .residential, osmStart: 100, osmEnd: 103)

        let joined = OSMConnectorMerger.merge(arcgis: graph, connectors: [j1, j2, j3])
        XCTAssertEqual(joined.crossingsConsidered, 1)
        XCTAssertEqual(joined.crossingsJoined, 1)
        let afterJoined = ConnectivityReport.make(from: joined.graph)
        XCTAssertEqual(afterJoined.crossingCount, 0)

        let bridgeArms = [
            connector(from: LocalPoint(x: 50, y: 50), to: LocalPoint(x: 50, y: 120), highway: .secondary, osmStart: 200, osmEnd: 201, isBridge: true),
            connector(from: LocalPoint(x: 50, y: 50), to: LocalPoint(x: 0, y: 50), highway: .secondary, osmStart: 200, osmEnd: 202, isBridge: true),
            connector(from: LocalPoint(x: 50, y: 50), to: LocalPoint(x: 100, y: 50), highway: .secondary, osmStart: 200, osmEnd: 203, isBridge: true)
        ]
        let bridged = OSMConnectorMerger.merge(arcgis: graph, connectors: bridgeArms)
        XCTAssertEqual(bridged.crossingsJoined, 0)
        let afterBridge = ConnectivityReport.make(from: bridged.graph)
        XCTAssertEqual(afterBridge.crossingCount, 1)
    }

    func testRouterUsesResidentialConnectorAndPrefersTrailOverPrimary() {
        // ArcGIS island at x=0 and main network at x=200, linked only via OSM.
        let island = route(points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 20, y: 0)], facility: .bikeLane, lts: 2)
        let main = route(points: [LocalPoint(x: 200, y: 0), LocalPoint(x: 400, y: 0)], facility: .pavedTrail, lts: nil)
        let trailAlt = route(points: [LocalPoint(x: 200, y: 0), LocalPoint(x: 200, y: 50), LocalPoint(x: 400, y: 50), LocalPoint(x: 400, y: 0)], facility: .pavedTrail, lts: nil)

        let graph = BikeNetworkGraphBuilder.build(from: [island, main, trailAlt], config: config)

        let residentialLink = connector(
            from: LocalPoint(x: 20, y: 0),
            to: LocalPoint(x: 200, y: 0),
            highway: .residential,
            osmStart: 300,
            osmEnd: 301
        )
        let primaryShortcut = connector(
            from: LocalPoint(x: 200, y: 0),
            to: LocalPoint(x: 400, y: 0),
            highway: .primary,
            osmStart: 301,
            osmEnd: 302
        )

        let merged = OSMConnectorMerger.merge(arcgis: graph, connectors: [residentialLink, primaryShortcut])
        let origin = at(LocalPoint(x: 0, y: 0))
        let destination = at(LocalPoint(x: 400, y: 0))
        let result = RouteFinder.route(from: origin, to: destination, graph: merged.graph)
        guard case .success(let planned) = result else {
            return XCTFail("Expected route across OSM connector, got \(result)")
        }
        XCTAssertTrue(planned.edges.contains { $0.isConnector && $0.osmClass == .residential })
        XCTAssertFalse(planned.edges.contains { $0.osmClass == .primary })
        XCTAssertGreaterThan(planned.connectorShare, 0)
    }

    func testDeltaDecodingRoundTripsWithinOnePointFiveMeters() {
        let original = [
            CLLocationCoordinate2D(latitude: 40.5853, longitude: -105.0844),
            CLLocationCoordinate2D(latitude: 40.5860, longitude: -105.0830),
            CLLocationCoordinate2D(latitude: 40.5875, longitude: -105.0810)
        ]
        var encoded: [Int] = []
        var prevLat = 0
        var prevLon = 0
        for (index, coordinate) in original.enumerated() {
            let latI = Int((coordinate.latitude * 1e5).rounded())
            let lonI = Int((coordinate.longitude * 1e5).rounded())
            if index == 0 {
                encoded.append(contentsOf: [latI, lonI])
            } else {
                encoded.append(contentsOf: [latI - prevLat, lonI - prevLon])
            }
            prevLat = latI
            prevLon = lonI
        }

        let decoded = OSMConnectorLoader.decodeCoordinates(encoded)
        XCTAssertEqual(decoded.count, original.count)
        let proj = LocalProjection(originLatitude: 40.5853, originLongitude: -105.0844)
        for i in original.indices {
            let d = proj.toLocal(original[i]).distance(to: proj.toLocal(decoded[i]))
            XCTAssertLessThan(d, 1.5, "coordinate \(i) drifted \(d) m")
        }
    }

    // MARK: - Helpers

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func route(
        points: [LocalPoint],
        facility: FacilityType,
        lts: Int? = 2
    ) -> BikeRoute {
        BikeRoute(
            id: UUID(),
            objectId: Int.random(in: 1...10_000),
            streetName: "ArcGIS",
            facilityType: facility,
            lts: lts,
            mapSymbolClass: nil,
            bikewayName: "ArcGIS",
            speedLimit: nil,
            paths: [points.map { at($0) }]
        )
    }

    private func connector(
        from: LocalPoint,
        to: LocalPoint,
        highway: OSMHighwayClass,
        osmStart: Int64,
        osmEnd: Int64,
        isBridge: Bool = false,
        isTunnel: Bool = false
    ) -> OSMConnectorEdge {
        OSMConnectorEdge(
            highwayClass: highway,
            name: highway.rawValue,
            isBridge: isBridge,
            isTunnel: isTunnel,
            startNodeID: osmStart,
            endNodeID: osmEnd,
            coordinates: [at(from), at(to)]
        )
    }
}
