import XCTest
import CoreLocation
@testable import BikeNoCo

final class RouteNamingTests: XCTestCase {
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

    // MARK: - routeLabel

    func testRouteLabelStripsDirectionalsAndShortensSuffix() {
        XCTAssertEqual(NameNormalizer.routeLabel("W LAUREL ST"), "Laurel St")
        XCTAssertEqual(NameNormalizer.routeLabel("West Laurel Street"), "Laurel St")
        XCTAssertEqual(NameNormalizer.routeLabel("N Mason Trail"), "Mason Trail")
        XCTAssertEqual(NameNormalizer.routeLabel("SPRING CREEK TRAIL"), "Spring Creek Trail")
    }

    func testRouteLabelLeavesDisplayNameWithDirectionalIntact() {
        // `displayName` keeps the compass prefix; `routeLabel` is for generated titles only.
        XCTAssertEqual(NameNormalizer.displayName("W LAUREL ST"), "W Laurel St")
        XCTAssertEqual(NameNormalizer.routeLabel("W LAUREL ST"), "Laurel St")
    }

    // MARK: - Open vs loop naming

    func testOpenRideUsesFirstToLastNamedRun() {
        let origin = at(LocalPoint(x: 0, y: 0))
        let mid = at(LocalPoint(x: 500, y: 0))
        let end = at(LocalPoint(x: 1_000, y: 0))
        let edges = [
            edge(id: 1, from: 0, to: 1, length: 500, name: "W LAUREL ST",
                 geometry: [origin, mid]),
            edge(id: 2, from: 1, to: 2, length: 500, name: "N MASON TRAIL",
                 geometry: [mid, end])
        ]
        let route = PlannedRoute.make(
            edges: edges,
            coordinates: [origin, mid, end],
            origin: origin,
            destination: end
        )

        XCTAssertFalse(TrackToRouteConverter.isClosedLoop(route))
        XCTAssertEqual(
            TrackToRouteConverter.suggestedName(for: route),
            "Laurel St to Mason Trail"
        )
    }

    func testClosedRideWithin200mAppendsLoop() {
        let origin = at(LocalPoint(x: 0, y: 0))
        let a = at(LocalPoint(x: 400, y: 0))
        let b = at(LocalPoint(x: 400, y: 300))
        // End 50 m from start — within 200 m closure.
        let end = at(LocalPoint(x: 50, y: 0))
        let edges = [
            edge(id: 1, from: 0, to: 1, length: 400, name: "Spring Creek Trail",
                 geometry: [origin, a]),
            edge(id: 2, from: 1, to: 2, length: 300, name: "Poudre Trail",
                 geometry: [a, b]),
            edge(id: 3, from: 2, to: 3, length: 350, name: "W MULBERRY ST",
                 geometry: [b, end])
        ]
        let route = PlannedRoute.make(
            edges: edges,
            coordinates: [origin, a, b, end],
            origin: origin,
            destination: end,
            tripShape: .loop
        )

        XCTAssertTrue(TrackToRouteConverter.isClosedLoop(route))
        let name = TrackToRouteConverter.suggestedName(for: route)
        XCTAssertTrue(name.hasSuffix(" Loop"), name)
        XCTAssertFalse(name.contains(" to "), name)
        // Dominant names are normalized for display.
        XCTAssertFalse(name.contains("W "), "directionals should be stripped: \(name)")
        XCTAssertFalse(name.contains("MULBERRY ST") && name.contains("W"), name)
    }

    func testOpenRideBeyond200mDoesNotAppendLoop() {
        let origin = at(LocalPoint(x: 0, y: 0))
        let end = at(LocalPoint(x: 500, y: 0)) // 500 m apart
        let edges = [
            edge(id: 1, from: 0, to: 1, length: 500, name: "Remington St",
                 geometry: [origin, end])
        ]
        let route = PlannedRoute.make(
            edges: edges,
            coordinates: [origin, end],
            origin: origin,
            destination: end
        )

        XCTAssertFalse(TrackToRouteConverter.isClosedLoop(route))
        let name = TrackToRouteConverter.suggestedName(for: route)
        XCTAssertEqual(name, "Remington St")
        XCTAssertFalse(name.hasSuffix(" Loop"))
    }

    func testDistanceLoopPlannerNameUsesRouteLabels() {
        let origin = at(LocalPoint(x: 0, y: 0))
        let edges = [
            edge(id: 1, from: 0, to: 1, length: 800, name: "W SPRING CREEK TRAIL",
                 geometry: [origin, at(LocalPoint(x: 800, y: 0))]),
            edge(id: 2, from: 1, to: 2, length: 600, name: "N POUDRE TRAIL",
                 geometry: [at(LocalPoint(x: 800, y: 0)), at(LocalPoint(x: 800, y: 600))]),
            edge(id: 3, from: 2, to: 0, length: 100, name: "Connector",
                 geometry: [at(LocalPoint(x: 800, y: 600)), origin]),
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

    // MARK: - Helpers

    private func at(_ point: LocalPoint) -> CLLocationCoordinate2D {
        projection.toCoordinate(point)
    }

    private func edge(
        id: Int,
        from: Int,
        to: Int,
        length: Double,
        name: String,
        geometry: [CLLocationCoordinate2D]
    ) -> GraphEdge {
        GraphEdge(
            id: id,
            fromID: from,
            toID: to,
            lengthMeters: length,
            geometry: geometry,
            facilityType: .bikeLane,
            lts: 2,
            name: name,
            sourceRouteID: UUID(),
            isConnector: false
        )
    }
}
