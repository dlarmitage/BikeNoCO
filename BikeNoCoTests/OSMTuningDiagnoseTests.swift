import XCTest
import CoreLocation
@testable import BikeNoCo

/// Live diagnose harness for task 03b. Not part of the default offline suite assertions
/// beyond fetch/build succeeding; prints stage timings and route edge breakdowns.
final class OSMTuningDiagnoseTests: XCTestCase {
    func testDiagnoseTimingsAndRouteBreakdowns() async throws {
        let routes = try await ArcGISService().fetchAllRoutes { _ in }
        XCTAssertFalse(routes.isEmpty)

        let decodeStart = CFAbsoluteTimeGetCurrent()
        let file = try OSMConnectorLoader.loadBundled()
        let decodeElapsed = CFAbsoluteTimeGetCurrent() - decodeStart

        let result = BikeNetworkGraphBuilder.build(from: routes, connectors: file.edges)
        var timing = result.timing
        timing.osmDecode = decodeElapsed
        // Cold rebuild wall clock = OSM decode + graph build (fetch is separate).
        timing.wallClock = decodeElapsed + result.timing.wallClock

        NSLog("[Diagnose] AFTER-OPTIMIZE stage timings:\n%@", timing.summary)

        let cacheKey = GraphCache.makeKey(routes: routes, osmTimestamp: file.meta.osmTimestamp)
        try GraphCache.save(graph: result.graph, key: cacheKey, osmTimestamp: file.meta.osmTimestamp)
        let cacheReadStart = CFAbsoluteTimeGetCurrent()
        let cached = try GraphCache.load(expectedKey: cacheKey)
        let cacheReadElapsed = CFAbsoluteTimeGetCurrent() - cacheReadStart
        XCTAssertNotNil(cached)
        NSLog("[Diagnose] cached load time: %.3fs", cacheReadElapsed)
        NSLog(
            "[Diagnose] prune: components=%d largest=%.1f%%  osm kept=%d/%d attachments=%d crossings joined=%d/%d",
            result.componentsAfterPrune,
            result.largestComponentShareAfterPrune * 100,
            result.osmEdgesKept,
            result.osmEdgesLoaded,
            result.attachmentEdgeCount,
            result.crossingsJoined,
            result.crossingsConsidered
        )

        let oldTown = CLLocationCoordinate2D(latitude: 40.5875, longitude: -105.0760)
        let samples: [(String, CLLocationCoordinate2D, CLLocationCoordinate2D)] = [
            ("Old Town → CSU", oldTown, CLLocationCoordinate2D(latitude: 40.5750, longitude: -105.0820)),
            ("Old Town → Spring Creek", oldTown, CLLocationCoordinate2D(latitude: 40.5665, longitude: -105.0705)),
            ("CSU → City Park", CLLocationCoordinate2D(latitude: 40.5750, longitude: -105.0820), CLLocationCoordinate2D(latitude: 40.5768, longitude: -105.0925)),
            ("Old Town → former off-network", oldTown, CLLocationCoordinate2D(latitude: 40.57900, longitude: -105.09800))
        ]

        for (label, origin, destination) in samples {
            let plannedResult = RouteFinder.route(from: origin, to: destination, graph: result.graph)
            switch plannedResult {
            case .success(let planned):
                NSLog(
                    "[Diagnose] %@ — %.2f mi, %.0f%% low-stress, %.0f%% connector",
                    label,
                    planned.totalDistanceMeters / 1609.344,
                    planned.lowStressShare * 100,
                    planned.connectorShare * 100
                )
                if label == "CSU → City Park" {
                    for (index, edge) in planned.edges.enumerated() {
                        let source: String
                        if let osm = edge.osmClass {
                            source = "OSM \(osm.rawValue)"
                        } else if edge.isConnector {
                            source = "synthetic"
                        } else {
                            source = "ArcGIS \(edge.facilityType.rawValue) LTS=\(edge.lts.map(String.init) ?? "nil")"
                        }
                        NSLog(
                            "[Diagnose]   %2d. %@  \"%@\"  %.1f m",
                            index + 1,
                            source,
                            edge.name,
                            edge.lengthMeters
                        )
                    }
                }
            case .failure(let error):
                NSLog("[Diagnose] %@ — FAILED: %@", label, error.friendlyMessage)
            }
        }
    }
}
