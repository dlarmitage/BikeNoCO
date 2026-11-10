import Foundation
import CoreLocation

enum GPXExporter {
    private static let sampleSpacingMeters = 5.0
    private static let speedMetersPerSecond = 12.0 * 1609.344 / 3600.0 // 12 mph

    /// Densified track points suitable for Xcode location simulation.
    static func trackPoints(for route: PlannedRoute) -> [(coordinate: CLLocationCoordinate2D, date: Date)] {
        guard route.coordinates.count >= 2 else {
            return [(route.origin, Date())]
        }
        let origin = route.coordinates[0]
        let projection = LocalProjection(
            originLatitude: origin.latitude,
            originLongitude: origin.longitude
        )
        let locals = route.coordinates.map { projection.toLocal($0) }

        var points: [(CLLocationCoordinate2D, Date)] = []
        let start = Date()
        points.append((route.coordinates[0], start))

        var traveled = 0.0
        var nextSample = sampleSpacingMeters
        for i in 0..<(locals.count - 1) {
            let a = locals[i]
            let b = locals[i + 1]
            let segLen = a.distance(to: b)
            guard segLen > 1e-9 else { continue }
            while nextSample <= traveled + segLen + 1e-9 {
                let t = (nextSample - traveled) / segLen
                let local = LocalPoint(
                    x: a.x + (b.x - a.x) * t,
                    y: a.y + (b.y - a.y) * t
                )
                let elapsed = nextSample / speedMetersPerSecond
                points.append((projection.toCoordinate(local), start.addingTimeInterval(elapsed)))
                nextSample += sampleSpacingMeters
            }
            traveled += segLen
        }

        let endElapsed = traveled / speedMetersPerSecond
        if let last = route.coordinates.last {
            points.append((last, start.addingTimeInterval(endElapsed)))
        }
        return points
    }

    static func gpxString(for route: PlannedRoute, name: String = "BikeNoCo Route") -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(
            #"<gpx version="1.1" creator="BikeNoCo" xmlns="http://www.topografix.com/GPX/1/1">"#
        )
        lines.append("<trk>")
        lines.append("<name>\(xmlEscape(name))</name>")
        lines.append("<trkseg>")
        for point in trackPoints(for: route) {
            lines.append(
                String(
                    format: "<trkpt lat=\"%.8f\" lon=\"%.8f\"><time>%@</time></trkpt>",
                    point.coordinate.latitude,
                    point.coordinate.longitude,
                    iso.string(from: point.date)
                )
            )
        }
        lines.append("</trkseg>")
        lines.append("</trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n")
    }

    static func writeTemporaryFile(for route: PlannedRoute, name: String = "BikeNoCo Route") throws -> URL {
        let data = Data(gpxString(for: route, name: name).utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bikenoco-route-\(UUID().uuidString).gpx")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
