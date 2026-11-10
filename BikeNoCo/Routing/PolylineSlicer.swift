import Foundation
import CoreLocation

/// Slices a route polyline by distance-along for navigation map display.
enum PolylineSlicer {
    /// Coordinates from `distanceAlong` to the end, starting at the exact point on the line.
    static func remaining(
        coordinates: [CLLocationCoordinate2D],
        fromDistanceAlong distanceAlong: Double
    ) -> [CLLocationCoordinate2D] {
        guard let point = interpolate(coordinates: coordinates, distanceAlong: distanceAlong) else {
            return coordinates
        }
        if point.target >= point.total - 0.5 {
            return coordinates.last.map { [$0] } ?? []
        }

        let start = point.coordinate
        var result = [start]
        if point.segmentIndex < coordinates.count {
            result.append(contentsOf: coordinates[point.segmentIndex...])
        }
        return result
    }

    /// Point on the polyline at `distanceAlong` meters from the start.
    static func coordinate(
        at distanceAlong: Double,
        along coordinates: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D? {
        interpolate(coordinates: coordinates, distanceAlong: distanceAlong)?.coordinate
    }

    /// Coordinates from the start through `distanceAlong` (inclusive of the interpolated end point).
    static func prefix(
        coordinates: [CLLocationCoordinate2D],
        untilDistanceAlong distanceAlong: Double
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return coordinates }
        guard let point = interpolate(coordinates: coordinates, distanceAlong: distanceAlong) else {
            return coordinates
        }
        if point.target <= 0.5 {
            return [coordinates[0], point.coordinate]
        }
        var result = Array(coordinates.prefix(point.segmentIndex))
        let last = result.last
        if last == nil
            || abs((last?.latitude ?? 0) - point.coordinate.latitude) > 1e-9
            || abs((last?.longitude ?? 0) - point.coordinate.longitude) > 1e-9 {
            result.append(point.coordinate)
        }
        return result.count >= 2 ? result : coordinates
    }

    private struct Interpolation {
        var coordinate: CLLocationCoordinate2D
        var segmentIndex: Int
        var target: Double
        var total: Double
    }

    private static func interpolate(
        coordinates: [CLLocationCoordinate2D],
        distanceAlong: Double
    ) -> Interpolation? {
        guard coordinates.count >= 2 else {
            guard let only = coordinates.first else { return nil }
            return Interpolation(coordinate: only, segmentIndex: 0, target: 0, total: 0)
        }
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
        guard total > 0 else {
            return Interpolation(coordinate: coordinates[0], segmentIndex: 0, target: 0, total: 0)
        }

        let target = min(max(0, distanceAlong), total)
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
        let coordinate = CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
        return Interpolation(coordinate: coordinate, segmentIndex: i, target: target, total: total)
    }
}
