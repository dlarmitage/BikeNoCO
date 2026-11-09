import Foundation
import CoreLocation

/// Planar meters in an equirectangular projection around a reference latitude.
struct LocalPoint: Equatable {
    var x: Double
    var y: Double

    func distance(to other: LocalPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }

    /// Projects this point onto segment `a`→`b`. `t` is clamped to [0, 1].
    func projected(ontoSegmentFrom a: LocalPoint, to b: LocalPoint) -> (point: LocalPoint, t: Double, distance: Double) {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        let t: Double
        if lengthSquared < 1e-18 {
            t = 0
        } else {
            t = max(0, min(1, ((x - a.x) * abx + (y - a.y) * aby) / lengthSquared))
        }
        let point = LocalPoint(x: a.x + t * abx, y: a.y + t * aby)
        return (point, t, distance(to: point))
    }
}

/// Equirectangular projection around a reference origin. Accurate to well under 1%
/// across the Fort Collins / Loveland service area.
struct LocalProjection {
    let originLatitude: Double
    let originLongitude: Double

    private static let earthRadiusMeters = 6_371_000.0

    private var metersPerDegreeLatitude: Double {
        Self.earthRadiusMeters * .pi / 180
    }

    private var metersPerDegreeLongitude: Double {
        metersPerDegreeLatitude * cos(originLatitude * .pi / 180)
    }

    func toLocal(_ coordinate: CLLocationCoordinate2D) -> LocalPoint {
        LocalPoint(
            x: (coordinate.longitude - originLongitude) * metersPerDegreeLongitude,
            y: (coordinate.latitude - originLatitude) * metersPerDegreeLatitude
        )
    }

    func toCoordinate(_ point: LocalPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: originLatitude + point.y / metersPerDegreeLatitude,
            longitude: originLongitude + point.x / metersPerDegreeLongitude
        )
    }

    /// Proper (interior) intersection of two segments, or nil if they miss, touch at an
    /// endpoint, or are collinear.
    static func properIntersection(
        a1: LocalPoint, a2: LocalPoint,
        b1: LocalPoint, b2: LocalPoint
    ) -> LocalPoint? {
        let d = (a2.x - a1.x) * (b2.y - b1.y) - (a2.y - a1.y) * (b2.x - b1.x)
        if abs(d) < 1e-12 { return nil }

        let t = ((b1.x - a1.x) * (b2.y - b1.y) - (b1.y - a1.y) * (b2.x - b1.x)) / d
        let u = ((b1.x - a1.x) * (a2.y - a1.y) - (b1.y - a1.y) * (a2.x - a1.x)) / d
        let eps = 1e-9
        guard t > eps, t < 1 - eps, u > eps, u < 1 - eps else { return nil }
        return LocalPoint(
            x: a1.x + t * (a2.x - a1.x),
            y: a1.y + t * (a2.y - a1.y)
        )
    }
}
