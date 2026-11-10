import XCTest
import CoreLocation
@testable import BikeNoCo

/// Live harness: prints loop metrics for sample via-points.
final class LoopDiagnoseTests: XCTestCase {
    func testPrintSampleLoops() async throws {
        let routes = try await ArcGISService().fetchAllRoutes { _ in }
        let file = try OSMConnectorLoader.loadBundled()
        let graph = BikeNetworkGraphBuilder.build(from: routes, connectors: file.edges).graph

        let oldTown = CLLocationCoordinate2D(latitude: 40.5875, longitude: -105.0760)
        let samples: [(String, CLLocationCoordinate2D, CLLocationCoordinate2D)] = [
            ("Old Town → CSU", oldTown, CLLocationCoordinate2D(latitude: 40.5750, longitude: -105.0820)),
            ("Old Town → Spring Creek", oldTown, CLLocationCoordinate2D(latitude: 40.5665, longitude: -105.0705)),
            ("Old Town → City Park", oldTown, CLLocationCoordinate2D(latitude: 40.5768, longitude: -105.0925)),
        ]

        for (label, origin, destination) in samples {
            let result = RouteFinder.loop(from: origin, via: destination, graph: graph)
            guard case .success(let looped) = result else {
                NSLog("[Loop] %@ — FAILED: %@", label, String(describing: result))
                continue
            }
            let outMi = (looped.outboundDistanceMeters ?? 0) / 1609.344
            let backMi = (looped.legs.count >= 2 ? looped.legs[1].distanceMeters : 0) / 1609.344
            let overlapPct = (looped.overlapShare ?? 0) * 100
            let lowStressPct = looped.lowStressShare * 100
            NSLog(
                "[Loop] %@ — out %.2f mi, back %.2f mi, overlap %.0f%%, low-stress %.0f%%, total %.2f mi",
                label,
                outMi,
                backMi,
                overlapPct,
                lowStressPct,
                looped.totalDistanceMeters / 1609.344
            )
            let maneuvers = ManeuverBuilder.build(from: looped)
            let pass = maneuvers.first { $0.instruction.hasPrefix("Passing") }
            NSLog(
                "[Loop]   pass-through: %@  arrive: %@",
                pass?.instruction ?? "(none)",
                maneuvers.last?.instruction ?? "(none)"
            )
        }
    }
}
