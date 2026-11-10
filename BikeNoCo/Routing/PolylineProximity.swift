import Foundation
import CoreLocation

/// Distance / proximity helpers between polylines in local planar meters.
enum PolylineProximity {
    /// Share of `sample` length that lies within `thresholdMeters` of `reference`.
    static func lengthShareWithin(
        sample: [CLLocationCoordinate2D],
        of reference: [CLLocationCoordinate2D],
        thresholdMeters: Double
    ) -> Double {
        guard sample.count >= 2, reference.count >= 2 else { return 0 }

        let origin = sample[0]
        let projection = LocalProjection(
            originLatitude: origin.latitude,
            originLongitude: origin.longitude
        )
        let sampleLocals = sample.map { projection.toLocal($0) }
        let referenceLocals = reference.map { projection.toLocal($0) }

        var within = 0.0
        var total = 0.0
        for i in 0..<(sampleLocals.count - 1) {
            let a = sampleLocals[i]
            let b = sampleLocals[i + 1]
            let segLen = a.distance(to: b)
            guard segLen > 1e-6 else { continue }
            total += segLen

            // Sample midpoints along the segment every ~10 m.
            let steps = max(1, Int(ceil(segLen / 10.0)))
            var covered = 0.0
            for step in 0..<steps {
                let t0 = Double(step) / Double(steps)
                let t1 = Double(step + 1) / Double(steps)
                let mid = LocalPoint(
                    x: a.x + (b.x - a.x) * ((t0 + t1) / 2),
                    y: a.y + (b.y - a.y) * ((t0 + t1) / 2)
                )
                if distance(from: mid, toPolyline: referenceLocals) <= thresholdMeters {
                    covered += segLen * (t1 - t0)
                }
            }
            within += covered
        }
        guard total > 0 else { return 0 }
        return within / total
    }

    /// Contiguous stretches along `routed` where distance to `track` exceeds `divergeMeters`.
    /// Returns (startDistanceAlong, endDistanceAlong, midpoint coordinate on track side).
    static func divergenceSpans(
        routed: [CLLocationCoordinate2D],
        track: [CLLocationCoordinate2D],
        divergeMeters: Double,
        minSpanMeters: Double
    ) -> [(start: Double, end: Double, insertCoordinate: CLLocationCoordinate2D)] {
        guard routed.count >= 2, track.count >= 2 else { return [] }

        let origin = routed[0]
        let projection = LocalProjection(
            originLatitude: origin.latitude,
            originLongitude: origin.longitude
        )
        let routedLocals = routed.map { projection.toLocal($0) }
        let trackLocals = track.map { projection.toLocal($0) }

        var cumulative: [Double] = [0]
        var total = 0.0
        for i in 1..<routedLocals.count {
            total += routedLocals[i - 1].distance(to: routedLocals[i])
            cumulative.append(total)
        }

        // Walk routed polyline every ~10 m and mark far samples.
        var samples: [(distance: Double, far: Bool, nearestTrack: CLLocationCoordinate2D)] = []
        let step = 10.0
        var d = 0.0
        while d <= total + 1e-6 {
            let point = point(at: d, locals: routedLocals, cumulative: cumulative)
            let nearest = nearestPoint(on: trackLocals, to: point)
            let far = point.distance(to: nearest.point) > divergeMeters
            samples.append((d, far, projection.toCoordinate(nearest.point)))
            d += step
        }

        var spans: [(start: Double, end: Double, insertCoordinate: CLLocationCoordinate2D)] = []
        var spanStart: Double?
        var spanInsert: CLLocationCoordinate2D?

        for sample in samples {
            if sample.far {
                if spanStart == nil {
                    spanStart = sample.distance
                    spanInsert = sample.nearestTrack
                }
            } else if let start = spanStart {
                let end = sample.distance
                if end - start >= minSpanMeters, let insert = spanInsert {
                    let mid = (start + end) / 2
                    // Prefer the track point nearest the midpoint of the routed span.
                    let routedMid = point(at: mid, locals: routedLocals, cumulative: cumulative)
                    let nearest = nearestPoint(on: trackLocals, to: routedMid)
                    spans.append((start, end, projection.toCoordinate(nearest.point)))
                }
                spanStart = nil
                spanInsert = nil
            }
        }
        if let start = spanStart, total - start >= minSpanMeters, let insert = spanInsert {
            let mid = (start + total) / 2
            let routedMid = point(at: mid, locals: routedLocals, cumulative: cumulative)
            let nearest = nearestPoint(on: trackLocals, to: routedMid)
            spans.append((start, total, projection.toCoordinate(nearest.point)))
            _ = insert
        }
        return spans
    }

    static func distance(
        from point: LocalPoint,
        toPolyline locals: [LocalPoint]
    ) -> Double {
        nearestPoint(on: locals, to: point).distance
    }

    static func nearestPoint(
        on locals: [LocalPoint],
        to point: LocalPoint
    ) -> (point: LocalPoint, distance: Double, tAlong: Double) {
        guard locals.count >= 2 else {
            let only = locals.first ?? point
            return (only, point.distance(to: only), 0)
        }
        var bestPoint = locals[0]
        var bestDistance = Double.infinity
        var bestAlong = 0.0
        var along = 0.0
        for i in 0..<(locals.count - 1) {
            let a = locals[i]
            let b = locals[i + 1]
            let projected = point.projected(ontoSegmentFrom: a, to: b)
            if projected.distance < bestDistance {
                bestDistance = projected.distance
                bestPoint = projected.point
                bestAlong = along + a.distance(to: b) * projected.t
            }
            along += a.distance(to: b)
        }
        return (bestPoint, bestDistance, bestAlong)
    }

    static func point(
        at distance: Double,
        locals: [LocalPoint],
        cumulative: [Double]
    ) -> LocalPoint {
        guard locals.count >= 2 else { return locals[0] }
        if distance <= 0 { return locals[0] }
        if distance >= cumulative.last! { return locals.last! }
        var lo = 0
        var hi = cumulative.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= distance {
                lo = mid
            } else {
                hi = mid
            }
        }
        let segLen = cumulative[hi] - cumulative[lo]
        let t = segLen > 1e-9 ? (distance - cumulative[lo]) / segLen : 0
        let a = locals[lo]
        let b = locals[hi]
        return LocalPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Cumulative distances along a coordinate polyline.
    static func cumulativeDistances(_ coordinates: [CLLocationCoordinate2D]) -> (locals: [LocalPoint], cumulative: [Double], total: Double, projection: LocalProjection) {
        precondition(!coordinates.isEmpty)
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
        return (locals, cumulative, total, projection)
    }
}
