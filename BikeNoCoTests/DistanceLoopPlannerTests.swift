import XCTest
import CoreLocation
@testable import BikeNoCo

final class DistanceLoopPlannerTests: XCTestCase {
    private let config = BikeNetworkGraphBuilder.Config(
        endpointSnapMeters: 8,
        gapSearchMeters: 25,
        originLatitude: 40.5,
        originLongitude: -105.0
    )

    private var projection: LocalProjection {
        LocalProjection(originLatitude: config.originLatitude, originLongitude: config.originLongitude)
    }

    func testRingRoadFindsLoopWithinTolerance() {
        // Octagon ring ~800 m radius → circumference ≈ 2πr ≈ 5 km.
        let radius = 800.0
        var routes: [BikeRoute] = []
        for i in 0..<8 {
            let a = Double(i) * 45.0
            let b = Double(i + 1) * 45.0
            routes.append(
                route(
                    points: [polar(radius, a), polar(radius, b)],
                    name: "Ring \(i)",
                    facility: .pavedTrail
                )
            )
        }
        // Spokes so the origin (center) snaps onto the network.
        for i in 0..<8 {
            let a = Double(i) * 45.0
            routes.append(
                route(
                    points: [LocalPoint(x: 0, y: 0), polar(radius, a)],
                    name: "Spoke \(i)",
                    facility: .bikeLane,
                    lts: 2
                )
            )
        }

        let graph = BikeNetworkGraphBuilder.build(from: routes, config: config)
        let origin = at(LocalPoint(x: 0, y: 0))
        // A triangle on the ring using two waypoints tends to cover ~3/8 to 1/2 of the
        // ring plus spokes — target near a typical closed walk on this graph.
        let target = 3_500.0
        let constraints = LoopSearchConstraints(
            origin: origin,
            targetDistanceMeters: target,
            tolerance: 0.10,
            maxLTS: nil,
            preferTrails: false
        )

        let result = DistanceLoopPlanner.search(
            constraints: constraints,
            graph: graph,
            randomOffsetDegrees: 0
        )
        XCTAssertFalse(result.candidates.isEmpty, "Expected at least one ring loop")
        for candidate in result.candidates {
            let error = abs(candidate.distanceMeters - target) / target
            XCTAssertLessThanOrEqual(error, 0.10, "Candidate \(candidate.name) off target")
            XCTAssertEqual(candidate.route.tripShape, .loop)
            XCTAssertEqual(candidate.route.legs.count, 3)
        }
    }

    func testDiversityFilterRemovesNearDuplicate() {
        let shared = [
            edge(id: 1, from: 0, to: 1, length: 500, name: "Shared"),
            edge(id: 2, from: 1, to: 2, length: 500, name: "Shared2"),
        ]
        let uniqueA = [edge(id: 3, from: 2, to: 0, length: 100, name: "A")]
        let uniqueB = [edge(id: 4, from: 2, to: 0, length: 100, name: "B")]
        let uniqueC = [
            edge(id: 10, from: 0, to: 3, length: 400, name: "C1"),
            edge(id: 11, from: 3, to: 4, length: 400, name: "C2"),
            edge(id: 12, from: 4, to: 0, length: 400, name: "C3"),
        ]

        let origin = at(LocalPoint(x: 0, y: 0))
        let routeA = PlannedRoute.make(
            edges: shared + uniqueA,
            coordinates: [origin, at(LocalPoint(x: 500, y: 0)), origin],
            origin: origin,
            destination: origin,
            tripShape: .loop
        )
        let routeB = PlannedRoute.make(
            edges: shared + uniqueB,
            coordinates: [origin, at(LocalPoint(x: 500, y: 0)), origin],
            origin: origin,
            destination: origin,
            tripShape: .loop
        )
        let routeC = PlannedRoute.make(
            edges: uniqueC,
            coordinates: [origin, at(LocalPoint(x: 0, y: 400)), origin],
            origin: origin,
            destination: origin,
            tripShape: .loop
        )

        let shareAB = DistanceLoopPlanner.sharedDistanceShare(routeB, of: routeA)
        XCTAssertGreaterThan(shareAB, 0.50, "A and B should share most of their distance")

        let shareCA = DistanceLoopPlanner.sharedDistanceShare(routeC, of: routeA)
        XCTAssertLessThan(shareCA, 0.50, "C should be distinct from A")
    }

    func testMaxLTSExcludesHighStressCandidates() {
        // Low-stress square west, high-stress square east. Prefer trails off, maxLTS=2.
        let west = square(origin: LocalPoint(x: -300, y: 0), size: 400, name: "West", lts: 2)
        let east = square(origin: LocalPoint(x: 300, y: 0), size: 400, name: "East", lts: 4)
        let hub = route(
            points: [LocalPoint(x: 0, y: 0), LocalPoint(x: -100, y: 0)],
            name: "Hub",
            facility: .bikeLane,
            lts: 2
        )
        let graph = BikeNetworkGraphBuilder.build(from: west + east + [hub], config: config)
        let origin = at(LocalPoint(x: 0, y: 0))

        let constraints = LoopSearchConstraints(
            origin: origin,
            targetDistanceMeters: 1_600,
            tolerance: 0.15,
            maxLTS: 2,
            preferTrails: false
        )
        let result = DistanceLoopPlanner.search(
            constraints: constraints,
            graph: graph,
            randomOffsetDegrees: 0
        )
        for candidate in result.candidates {
            let high = candidate.route.edges.contains { ($0.lts ?? 0) > 2 }
            XCTAssertFalse(high, "maxLTS=2 should exclude LTS 3+ edges: \(candidate.name)")
        }
    }

    func testCancellationStopsPromptly() {
        let routes = square(origin: LocalPoint(x: 0, y: 0), size: 500, name: "Sq", lts: 2)
        let spokes = (0..<8).map { i -> BikeRoute in
            let a = Double(i) * 45.0
            return route(
                points: [LocalPoint(x: 0, y: 0), polar(250, a)],
                name: "S\(i)",
                facility: .bikeLane,
                lts: 2
            )
        }
        let graph = BikeNetworkGraphBuilder.build(from: routes + spokes, config: config)
        let origin = at(LocalPoint(x: 0, y: 0))
        let constraints = LoopSearchConstraints(
            origin: origin,
            targetDistanceMeters: 2_000,
            tolerance: 0.10
        )

        var calls = 0
        let started = CFAbsoluteTimeGetCurrent()
        let result = DistanceLoopPlanner.search(
            constraints: constraints,
            graph: graph,
            randomOffsetDegrees: 0,
            isCancelled: {
                calls += 1
                return true
            }
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertLessThan(elapsed, 0.5, "Cancelled search should return promptly")
        XCTAssertTrue(result.candidates.isEmpty || calls >= 1)
    }

    func testUnsnappableWaypointIsSkippedNotCrash() {
        // Only a tiny island at the origin — waypoints at 2 km cannot snap.
        let island = route(
            points: [LocalPoint(x: 0, y: 0), LocalPoint(x: 40, y: 0)],
            name: "Island",
            facility: .bikeLane,
            lts: 2
        )
        let graph = BikeNetworkGraphBuilder.build(from: [island], config: config)
        let origin = at(LocalPoint(x: 0, y: 0))
        let constraints = LoopSearchConstraints(
            origin: origin,
            targetDistanceMeters: 10_000,
            tolerance: 0.10
        )
        let result = DistanceLoopPlanner.search(
            constraints: constraints,
            graph: graph,
            randomOffsetDegrees: 0
        )
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testCardinalNamingAndDominantFeatureNaming() {
        XCTAssertEqual(DistanceLoopPlanner.cardinalName(degrees: 0), "North")
        XCTAssertEqual(DistanceLoopPlanner.cardinalName(degrees: 90), "East")
        XCTAssertEqual(DistanceLoopPlanner.cardinalName(degrees: 225), "Southwest")

        let origin = at(LocalPoint(x: 0, y: 0))
        let edges = [
            edge(id: 1, from: 0, to: 1, length: 800, name: "Spring Creek Trail"),
            edge(id: 2, from: 1, to: 2, length: 600, name: "Poudre Trail"),
            edge(id: 3, from: 2, to: 0, length: 100, name: "Connector"),
        ]
        let route = PlannedRoute.make(
            edges: edges,
            coordinates: [origin, at(LocalPoint(x: 800, y: 0)), origin],
            origin: origin,
            destination: origin,
            tripShape: .loop
        )
        let name = DistanceLoopPlanner.name(for: route, bearingDegrees: 45)
        XCTAssertEqual(name, "Spring Creek Trail and Poudre Trail Loop")
    }

    func testPreferTrailsMultipliesNonTrailEdgeCost() {
        let trail = GraphEdge(
            id: 1, fromID: 0, toID: 1, lengthMeters: 100,
            geometry: [at(LocalPoint(x: 0, y: 0)), at(LocalPoint(x: 100, y: 0))],
            facilityType: .pavedTrail, lts: nil, name: "Trail",
            sourceRouteID: UUID(), isConnector: false
        )
        let street = GraphEdge(
            id: 2, fromID: 0, toID: 1, lengthMeters: 100,
            geometry: [at(LocalPoint(x: 0, y: 0)), at(LocalPoint(x: 100, y: 0))],
            facilityType: .bikeLane, lts: 2, name: "Street",
            sourceRouteID: UUID(), isConnector: false
        )
        var profile = RoutingProfile.default
        let baseStreet = profile.cost(for: street)!
        let baseTrail = profile.cost(for: trail)!

        profile.preferTrails = true
        XCTAssertEqual(profile.cost(for: trail)!, baseTrail, accuracy: 1e-9)
        XCTAssertEqual(
            profile.cost(for: street)!,
            baseStreet * RoutingProfile.preferTrailsNonTrailMultiplier,
            accuracy: 1e-9
        )
        XCTAssertTrue(RoutingProfile.isPreferredTrail(trail))
        XCTAssertFalse(RoutingProfile.isPreferredTrail(street))
    }

    func testPreferTrailsPicksLongerTrailLoopOverShorterStreetLoop() {
        // Trail spokes from the hub + detouring trail ring, with short street chords
        // as the only non-trail shortcut. Waypoints snap onto trail spokes (no street
        // geometry there), so preferTrails flips the W1→W2 leg from street chord to
        // the longer trail ring.
        let radius = 800.0
        let graph = makePreferTrailsLoopGraph(radius: radius)
        let origin = at(LocalPoint(x: 0, y: 0))
        let target = 2_900.0

        let defaultResult = DistanceLoopPlanner.search(
            constraints: LoopSearchConstraints(
                origin: origin,
                targetDistanceMeters: target,
                tolerance: 0.15,
                preferTrails: false
            ),
            graph: graph,
            randomOffsetDegrees: 0
        )
        let trailResult = DistanceLoopPlanner.search(
            constraints: LoopSearchConstraints(
                origin: origin,
                targetDistanceMeters: target,
                tolerance: 0.15,
                preferTrails: true
            ),
            graph: graph,
            randomOffsetDegrees: 0
        )

        XCTAssertFalse(defaultResult.candidates.isEmpty, "Expected default loop")
        XCTAssertFalse(trailResult.candidates.isEmpty, "Expected prefer-trails loop")
        guard let defaultTop = defaultResult.candidates.first,
              let trailTop = trailResult.candidates.first else {
            return
        }

        let defaultStreet = defaultTop.route.edges.filter { $0.facilityType == .bikeLane }
            .reduce(0.0) { $0 + $1.lengthMeters }
        let preferStreet = trailTop.route.edges.filter { $0.facilityType == .bikeLane }
            .reduce(0.0) { $0 + $1.lengthMeters }
        XCTAssertGreaterThan(
            defaultStreet,
            preferStreet + 100,
            "Prefer trails should drop street chord mileage (default street \(Int(defaultStreet)) m, prefer \(Int(preferStreet)) m; trail \(String(format: "%.0f%%", defaultTop.trailShare * 100)) vs \(String(format: "%.0f%%", trailTop.trailShare * 100)); \(Int(defaultTop.distanceMeters)) m vs \(Int(trailTop.distanceMeters)) m)"
        )
        XCTAssertGreaterThan(
            trailTop.trailShare,
            defaultTop.trailShare + 0.10,
            "Prefer trails should raise trail share (default \(String(format: "%.0f%%", defaultTop.trailShare * 100)), trails \(String(format: "%.0f%%", trailTop.trailShare * 100)))"
        )
        XCTAssertGreaterThan(trailTop.distanceMeters, defaultTop.distanceMeters - 1)
    }

    func testStreamingPublishesShortlistBeforeSearchCompletes() {
        let radius = 800.0
        var routes: [BikeRoute] = []
        for i in 0..<8 {
            let a = Double(i) * 45.0
            let b = Double(i + 1) * 45.0
            routes.append(route(
                points: [polar(radius, a), polar(radius, b)],
                name: "Ring \(i)",
                facility: .pavedTrail
            ))
            routes.append(route(
                points: [LocalPoint(x: 0, y: 0), polar(radius, a)],
                name: "Spoke \(i)",
                facility: .bikeLane,
                lts: 2
            ))
        }
        let graph = BikeNetworkGraphBuilder.build(from: routes, config: config)
        let origin = at(LocalPoint(x: 0, y: 0))

        let lock = NSLock()
        var updates: [[LoopCandidate]] = []
        let result = DistanceLoopPlanner.search(
            constraints: LoopSearchConstraints(
                origin: origin,
                targetDistanceMeters: 3_500,
                tolerance: 0.10
            ),
            graph: graph,
            randomOffsetDegrees: 0,
            onShortlistChanged: { shortlist in
                lock.lock()
                updates.append(shortlist)
                lock.unlock()
            }
        )

        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertNotNil(result.timeToFirstResultSeconds)
        XCTAssertLessThan(result.timeToFirstResultSeconds!, result.elapsedSeconds + 0.01)
        lock.lock()
        let updateCount = updates.count
        let firstCount = updates.first?.count ?? 0
        lock.unlock()
        XCTAssertGreaterThanOrEqual(updateCount, 1, "Expected streamed shortlist updates")
        XCTAssertGreaterThanOrEqual(firstCount, 1)
    }

    // MARK: - Helpers

    /// Hub with trail-only spokes, a detouring trail ring, and short street chords
    /// (rim i → rim i+2). Built by hand so T-junction snap cannot fold alternatives.
    private func makePreferTrailsLoopGraph(radius: Double) -> BikeNetworkGraph {
        var nodesByID: [Int: GraphNode] = [:]
        var edgesByID: [Int: GraphEdge] = [:]
        var adjacency: [Int: [Int]] = [:]
        var nextEdgeID = 0
        let source = UUID()

        func addNode(id: Int, point: LocalPoint) {
            nodesByID[id] = GraphNode(id: id, coordinate: at(point))
        }

        func addEdge(
            from: Int,
            to: Int,
            via: [LocalPoint],
            facility: FacilityType,
            lts: Int?,
            name: String
        ) {
            let geometry = via.map { at($0) }
            var length = 0.0
            for i in 1..<via.count {
                length += via[i - 1].distance(to: via[i])
            }
            let id = nextEdgeID
            nextEdgeID += 1
            let edge = GraphEdge(
                id: id,
                fromID: from,
                toID: to,
                lengthMeters: length,
                geometry: geometry,
                facilityType: facility,
                lts: lts,
                name: name,
                sourceRouteID: source,
                isConnector: false
            )
            edgesByID[id] = edge
            adjacency[from, default: []].append(id)
            adjacency[to, default: []].append(id)
        }

        let originID = 0
        addNode(id: originID, point: LocalPoint(x: 0, y: 0))
        // Rim 1…8, trail-ring outer mids 9…16.
        for i in 0..<8 {
            let bearing = Double(i) * 45.0
            let rimID = 1 + i
            let rim = polar(radius, bearing)
            addNode(id: rimID, point: rim)
            addEdge(
                from: originID,
                to: rimID,
                via: [LocalPoint(x: 0, y: 0), rim],
                facility: .pavedTrail,
                lts: nil,
                name: "TrailSpoke \(i)"
            )
        }
        for i in 0..<8 {
            let a = 1 + i
            let b = 1 + ((i + 1) % 8)
            let midID = 9 + i
            let b0 = Double(i) * 45.0
            let b1 = Double(i + 1) * 45.0
            let mid = polar(radius * 1.2, b0 + 22.5)
            addNode(id: midID, point: mid)
            addEdge(
                from: a,
                to: midID,
                via: [polar(radius, b0), mid],
                facility: .pavedTrail,
                lts: nil,
                name: "TrailRing \(i)a"
            )
            addEdge(
                from: midID,
                to: b,
                via: [mid, polar(radius, b1)],
                facility: .pavedTrail,
                lts: nil,
                name: "TrailRing \(i)b"
            )
            // Street shortcut spanning two sectors (~90°).
            let c = 1 + ((i + 2) % 8)
            addEdge(
                from: a,
                to: c,
                via: [polar(radius, b0), polar(radius, Double(i + 2) * 45.0)],
                facility: .bikeLane,
                lts: 2,
                name: "StreetChord \(i)"
            )
        }

        return BikeNetworkGraph(
            nodesByID: nodesByID,
            edgesByID: edgesByID,
            adjacency: adjacency,
            projection: projection
        )
    }

    private func ring(
        radius: Double,
        count: Int,
        name: String,
        facility: FacilityType,
        lts: Int?
    ) -> [BikeRoute] {
        (0..<count).map { i in
            let a = Double(i) * (360.0 / Double(count))
            let b = Double(i + 1) * (360.0 / Double(count))
            return route(
                points: [polar(radius, a), polar(radius, b)],
                name: "\(name) \(i)",
                facility: facility,
                lts: lts
            )
        }
    }

    private func square(
        origin: LocalPoint,
        size: Double,
        name: String,
        lts: Int?,
        facility: FacilityType = .bikeLane
    ) -> [BikeRoute] {
        let half = size / 2
        let corners = [
            LocalPoint(x: origin.x - half, y: origin.y - half),
            LocalPoint(x: origin.x + half, y: origin.y - half),
            LocalPoint(x: origin.x + half, y: origin.y + half),
            LocalPoint(x: origin.x - half, y: origin.y + half),
        ]
        return (0..<4).map { i in
            route(
                points: [corners[i], corners[(i + 1) % 4]],
                name: "\(name)-\(i)",
                facility: facility,
                lts: lts
            )
        }
    }

    private func polar(_ radius: Double, _ bearingDegrees: Double) -> LocalPoint {
        let radians = bearingDegrees * .pi / 180
        return LocalPoint(x: radius * sin(radians), y: radius * cos(radians))
    }

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func route(
        points: [LocalPoint],
        name: String,
        facility: FacilityType,
        lts: Int? = nil
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

    private func edge(
        id: Int,
        from: Int,
        to: Int,
        length: Double,
        name: String
    ) -> GraphEdge {
        GraphEdge(
            id: id,
            fromID: from,
            toID: to,
            lengthMeters: length,
            geometry: [
                at(LocalPoint(x: Double(from) * 10, y: 0)),
                at(LocalPoint(x: Double(to) * 10, y: 0)),
            ],
            facilityType: .pavedTrail,
            lts: nil,
            name: name,
            sourceRouteID: UUID(),
            isConnector: false
        )
    }
}
