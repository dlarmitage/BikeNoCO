import XCTest
import CoreLocation
@testable import BikeNoCo

/// Live harness: prints distance-loop search metrics from Old Town.
final class DistanceLoopDiagnoseTests: XCTestCase {
    func testPrintOldTownLoopSearches() async throws {
        let routes = try await ArcGISService().fetchAllRoutes { _ in }
        let file = try OSMConnectorLoader.loadBundled()
        let graph = BikeNetworkGraphBuilder.build(from: routes, connectors: file.edges).graph

        let oldTown = CLLocationCoordinate2D(latitude: 40.5875, longitude: -105.0760)
        let runs: [(String, Double, Bool)] = [
            ("10 mi default", 10, false),
            ("10 mi prefer trails", 10, true),
            ("15 mi default", 15, false),
            ("20 mi default", 20, false),
        ]

        for (label, miles, preferTrails) in runs {
            let constraints = LoopSearchConstraints(
                origin: oldTown,
                targetDistanceMeters: miles * 1609.344,
                tolerance: 0.10,
                maxLTS: nil,
                preferTrails: preferTrails,
                minTrailShare: nil
            )
            let result = DistanceLoopPlanner.search(
                constraints: constraints,
                graph: graph,
                randomOffsetDegrees: 0
            )
            NSLog(
                "[DistanceLoop] %@ — total %.2fs, first %.2fs, %d candidates",
                label,
                result.elapsedSeconds,
                result.timeToFirstResultSeconds ?? -1,
                result.candidates.count
            )
            if result.candidates.isEmpty {
                NSLog("[DistanceLoop]   (none)")
            }
            for (index, candidate) in result.candidates.enumerated() {
                NSLog(
                    "[DistanceLoop]   %d. %@ — %.2f mi, low-stress %.0f%%, trail %.0f%%, overlap %.0f%%, score %.2f",
                    index + 1,
                    candidate.name,
                    candidate.distanceMeters / 1609.344,
                    candidate.lowStressShare * 100,
                    candidate.trailShare * 100,
                    candidate.overlapShare * 100,
                    candidate.score
                )
            }
        }
    }
}
