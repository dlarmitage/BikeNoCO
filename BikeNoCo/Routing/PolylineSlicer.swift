import Foundation
import CoreLocation

/// Slices a route polyline by distance-along for navigation map display.
enum PolylineSlicer {
    /// Coordinates from `distanceAlong` to the end, starting at the exact point on the line.
    static func remaining(
        coordinates: [CLLocationCoordinate2D],
        fromDistanceAlong distanceAlong: Double
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return coordinates }
        let projection = LocalProjection(
            originLatitude: coordinates[0].latitude,
            originLongitude: coordinates[0].longitude
        )
        let locals = coordinates.map { projection.toLocal($0) }
        var cumulative: [Double] = [0]
        var total = 0.0
        for i in 1..<locals.count {
            total += locals[i - 1].distance(to: locals[i])
            cumulative.append(total)
        }
        guard total > 0 else { return coordinates }

        let target = min(max(0, distanceAlong), total)
        if target >= total - 0.5 {
            return [coordinates.last!]
        }

        var index = 1
        while index < cumulative.count, cumulative[index] < target {
            index += 1
        }
        let i = min(max(1, index), coordinates.count - 1)
        let d0 = cumulative[i - 1]
        let d1 = cumulative[i]
        let seg = max(d1 - d0, 1e-9)
        let t = (target - d0) / seg
        let a = coordinates[i - 1]
        let b = coordinates[i]
        let start = CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )

        var result = [start]
        if i < coordinates.count {
            result.append(contentsOf: coordinates[i...])
        }
        return result
    }
}
