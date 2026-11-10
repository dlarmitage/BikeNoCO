#if DEBUG
import Foundation
import CoreLocation
import Combine

/// DEBUG-only publisher that walks a route polyline at a fixed speed for desk testing.
enum RideSimulator {
    static let defaultSpeedMPS: Double = 12 * 0.44704 // 12 mph

    static func publisher(
        coordinates: [CLLocationCoordinate2D],
        speedMPS: Double = defaultSpeedMPS,
        injectDetour: Bool = false,
        tickInterval: TimeInterval = 0.5
    ) -> AnyPublisher<CLLocation, Never> {
        let samples = buildSamples(
            coordinates: coordinates,
            speedMPS: speedMPS,
            injectDetour: injectDetour,
            tickInterval: tickInterval
        )
        guard !samples.isEmpty else {
            return Empty().eraseToAnyPublisher()
        }

        let subject = PassthroughSubject<CLLocation, Never>()
        let start = Date()

        // Fire on a background queue; LocationProvider hops to MainActor.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: tickInterval)
        var index = 0
        timer.setEventHandler {
            if index >= samples.count {
                timer.cancel()
                subject.send(completion: .finished)
                return
            }
            let sample = samples[index]
            index += 1
            let location = CLLocation(
                coordinate: sample.coordinate,
                altitude: 1500,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: sample.course,
                speed: speedMPS,
                timestamp: start.addingTimeInterval(sample.timeOffset)
            )
            subject.send(location)
        }
        timer.resume()

        return subject
            .handleEvents(receiveCancel: { timer.cancel() })
            .eraseToAnyPublisher()
    }

    private struct Sample {
        var coordinate: CLLocationCoordinate2D
        var course: CLLocationDirection
        var timeOffset: TimeInterval
    }

    private static func buildSamples(
        coordinates: [CLLocationCoordinate2D],
        speedMPS: Double,
        injectDetour: Bool,
        tickInterval: TimeInterval
    ) -> [Sample] {
        guard coordinates.count >= 2, speedMPS > 0 else { return [] }

        let origin = coordinates[0]
        let projection = LocalProjection(
            originLatitude: origin.latitude,
            originLongitude: origin.longitude
        )
        let locals = coordinates.map { projection.toLocal($0) }

        var cumulative: [Double] = [0]
        var total = 0.0
        for i in 1..<locals.count {
            total += locals[i - 1].distance(to: locals[i])
            cumulative.append(total)
        }
        guard total > 0 else { return [] }

        let step = speedMPS * tickInterval
        let detourStart = total * 0.5
        let detourLength = min(120.0, total * 0.15)
        let detourEnd = detourStart + detourLength

        var samples: [Sample] = []
        var distance = 0.0
        var timeOffset: TimeInterval = 0
        while distance <= total {
            var point = pointAlong(distance: distance, locals: locals, cumulative: cumulative)
            if injectDetour, distance >= detourStart, distance <= detourEnd {
                // Offset ~100 m to the right of travel direction.
                let bearing = tangent(at: distance, locals: locals, cumulative: cumulative)
                let right = bearing + .pi / 2
                point = LocalPoint(
                    x: point.x + cos(right) * 100,
                    y: point.y + sin(right) * 100
                )
            }
            let courseDegrees = tangentDegrees(at: distance, locals: locals, cumulative: cumulative)
            samples.append(
                Sample(
                    coordinate: projection.toCoordinate(point),
                    course: courseDegrees,
                    timeOffset: timeOffset
                )
            )
            distance += step
            timeOffset += tickInterval
        }

        // Ensure the final destination sample is included.
        if let last = coordinates.last {
            samples.append(
                Sample(coordinate: last, course: samples.last?.course ?? 0, timeOffset: timeOffset)
            )
        }
        return samples
    }

    private static func pointAlong(
        distance: Double,
        locals: [LocalPoint],
        cumulative: [Double]
    ) -> LocalPoint {
        let target = min(max(0, distance), cumulative.last ?? 0)
        var i = 1
        while i < cumulative.count, cumulative[i] < target {
            i += 1
        }
        i = min(max(1, i), locals.count - 1)
        let d0 = cumulative[i - 1]
        let d1 = cumulative[i]
        let seg = max(d1 - d0, 1e-9)
        let t = (target - d0) / seg
        let a = locals[i - 1]
        let b = locals[i]
        return LocalPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func tangent(
        at distance: Double,
        locals: [LocalPoint],
        cumulative: [Double]
    ) -> Double {
        let a = pointAlong(distance: distance, locals: locals, cumulative: cumulative)
        let b = pointAlong(distance: distance + 5, locals: locals, cumulative: cumulative)
        return atan2(b.y - a.y, b.x - a.x)
    }

    private static func tangentDegrees(
        at distance: Double,
        locals: [LocalPoint],
        cumulative: [Double]
    ) -> CLLocationDirection {
        let radians = tangent(at: distance, locals: locals, cumulative: cumulative)
        var degrees = radians * 180 / .pi
        // Convert from math angle (x/y) to course (degrees clockwise from north).
        degrees = 90 - degrees
        if degrees < 0 { degrees += 360 }
        return degrees
    }
}
#endif
