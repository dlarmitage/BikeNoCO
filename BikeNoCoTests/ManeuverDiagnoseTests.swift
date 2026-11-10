import XCTest
import CoreLocation
@testable import BikeNoCo

/// Live harness: prints maneuver lists for the four sample routes.
final class ManeuverDiagnoseTests: XCTestCase {
    func testPrintSampleRouteManeuvers() async throws {
        let routes = try await ArcGISService().fetchAllRoutes { _ in }
        let file = try OSMConnectorLoader.loadBundled()
        let graph = BikeNetworkGraphBuilder.build(from: routes, connectors: file.edges).graph

        let oldTown = CLLocationCoordinate2D(latitude: 40.5875, longitude: -105.0760)
        let samples: [(String, CLLocationCoordinate2D, CLLocationCoordinate2D)] = [
            ("Old Town → CSU", oldTown, CLLocationCoordinate2D(latitude: 40.5750, longitude: -105.0820)),
            ("Old Town → Spring Creek", oldTown, CLLocationCoordinate2D(latitude: 40.5665, longitude: -105.0705)),
            ("CSU → City Park", CLLocationCoordinate2D(latitude: 40.5750, longitude: -105.0820), CLLocationCoordinate2D(latitude: 40.5768, longitude: -105.0925)),
            ("Old Town → former off-network", oldTown, CLLocationCoordinate2D(latitude: 40.57900, longitude: -105.09800))
        ]

        for (label, origin, destination) in samples {
            let result = RouteFinder.route(from: origin, to: destination, graph: graph)
            guard case .success(let planned) = result else {
                NSLog("[Maneuvers] %@ — FAILED: %@", label, String(describing: result))
                continue
            }
            if label == "Old Town → former off-network" {
                dumpRunsForABADebug(planned)
            }
            let maneuvers = ManeuverBuilder.build(from: planned)
            NSLog(
                "[Maneuvers] %@ — %.2f mi, %d cues",
                label,
                planned.totalDistanceMeters / 1609.344,
                maneuvers.count
            )
            var cumulative = 0.0
            for (index, maneuver) in maneuvers.enumerated() {
                if let degrees = maneuver.turnAngleDegrees {
                    cumulative += degrees
                }
                let angle: String
                if let degrees = maneuver.turnAngleDegrees {
                    angle = String(format: "%+.0f°", degrees)
                } else {
                    angle = "—"
                }
                NSLog(
                    "[Maneuvers]   %2d. %@  %@  cum=%+.0f°  @%.0fm  next %@  \"%@\"",
                    index + 1,
                    maneuver.type.rawValue,
                    angle,
                    cumulative,
                    maneuver.distanceAlongRoute,
                    DistanceFormat.imperial(maneuver.distanceToNext),
                    maneuver.instruction
                )
            }
            let finalHeading = ManeuverBuilder.diagnoseFinalHeading(for: planned)
            let departBearing = ManeuverBuilder.diagnoseDepartBearing(for: planned)
            let expectedFinal = normalizeHeading(departBearing + cumulative)
            let delta = abs(signedHeadingDelta(from: expectedFinal, to: finalHeading))
            NSLog(
                "[Maneuvers]   sanity: depart=%.0f° cum=%+.0f° => expect final=%.0f°  actual last-30m=%.0f°  Δ=%.0f°",
                departBearing,
                cumulative,
                expectedFinal,
                finalHeading,
                delta
            )
            if delta > 20 {
                NSLog("[Maneuvers]   WARNING: cumulative heading mismatch > 20°")
            }
        }
    }

    private func dumpRunsForABADebug(_ planned: PlannedRoute) {
        let runs = ManeuverBuilder.diagnoseRuns(for: planned)
        NSLog("[Maneuvers] ABA debug — %d runs before A-B-A:", runs.count)
        for (index, run) in runs.enumerated() {
            let rawUnique = Array(Set(run.rawEdgeNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
                .sorted()
            let normalized = rawUnique.map { raw -> String in
                if raw.isEmpty { return "(unnamed) → \(run.compareKey)" }
                return "\"\(raw)\" → \"\(NameNormalizer.normalize(raw))\""
            }
            NSLog(
                "[Maneuvers]   run %d: display=%@ key=%@ len=%.1fm @%.0f–%.0fm named=%@ raw/norm=%@",
                index,
                run.displayName ?? "nil",
                run.compareKey,
                run.lengthMeters,
                run.startDistanceAlong,
                run.endDistanceAlong,
                run.isNamed ? "yes" : "no",
                normalized.joined(separator: "; ")
            )
        }

        // Explicit Laporte / path / Laporte hop report.
        for index in 1..<(max(runs.count - 1, 1)) {
            let before = runs[index - 1]
            let middle = runs[index]
            let after = runs[index + 1]
            let beforeLooksLaporte = (before.displayName ?? "").localizedCaseInsensitiveContains("laporte")
                || before.compareKey.contains("laporte")
            let afterLooksLaporte = (after.displayName ?? "").localizedCaseInsensitiveContains("laporte")
                || after.compareKey.contains("laporte")
            let middleIsPath = middle.compareKey == "__path__"
                || (middle.displayName ?? "").localizedCaseInsensitiveContains("path")
            guard beforeLooksLaporte, afterLooksLaporte, middleIsPath else { continue }

            let beforeRaws = before.rawEdgeNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let afterRaws = after.rawEdgeNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let beforeRaw = beforeRaws.last ?? before.displayName ?? "?"
            let afterRaw = afterRaws.first ?? after.displayName ?? "?"
            NSLog(
                "[Maneuvers] Laporte/path/Laporte hop: before raw=\"%@\" norm=\"%@\" | path len=%.1fm | after raw=\"%@\" norm=\"%@\" | keys equal=%@",
                beforeRaw,
                NameNormalizer.normalize(beforeRaw),
                middle.lengthMeters,
                afterRaw,
                NameNormalizer.normalize(afterRaw),
                before.compareKey == after.compareKey ? "yes" : "no"
            )
        }
    }

    private func normalizeHeading(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    private func signedHeadingDelta(from: Double, to: Double) -> Double {
        var delta = to - from
        while delta <= -180 { delta += 360 }
        while delta > 180 { delta -= 360 }
        return delta
    }
}
