import CoreLocation

struct TrackPoint {
    let coordinate: CLLocationCoordinate2D
    let altitude: Double        // meters MSL
    let speed: Double           // m/s, negative if invalid
    let timestamp: Date
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
}

struct RideSession: Identifiable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let trackPoints: [TrackPoint]

    let distanceMeters: Double
    let avgSpeedMPS: Double
    let maxSpeedMPS: Double
    let elevationGainMeters: Double
    let elevationLossMeters: Double
    let estimatedCalories: Double

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
    var distanceMiles: Double   { distanceMeters / 1609.344 }
    var avgSpeedMPH: Double     { avgSpeedMPS * 2.23694 }
    var maxSpeedMPH: Double     { maxSpeedMPS * 2.23694 }
    var elevationGainFeet: Double  { elevationGainMeters * 3.28084 }
    var elevationLossFeet: Double  { elevationLossMeters * 3.28084 }
    var coordinates: [CLLocationCoordinate2D] { trackPoints.map { $0.coordinate } }

    static func calculate(points: [TrackPoint], start: Date, end: Date) -> RideSession {
        let accurate = points.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 30 }

        // Distance
        var totalDistance: Double = 0
        guard accurate.count > 1 else {
            return RideSession(id: UUID(), startDate: start, endDate: end, trackPoints: accurate,
                               distanceMeters: 0, avgSpeedMPS: 0, maxSpeedMPS: 0,
                               elevationGainMeters: 0, elevationLossMeters: 0, estimatedCalories: 0)
        }
        for i in 1..<accurate.count {
            let a = CLLocation(latitude: accurate[i-1].coordinate.latitude, longitude: accurate[i-1].coordinate.longitude)
            let b = CLLocation(latitude: accurate[i].coordinate.latitude, longitude: accurate[i].coordinate.longitude)
            totalDistance += a.distance(from: b)
        }

        // Speed
        let validSpeeds = accurate.compactMap { $0.speed >= 0 ? $0.speed : nil }
        let avgSpeed = validSpeeds.isEmpty ? 0 : validSpeeds.reduce(0, +) / Double(validSpeeds.count)
        let maxSpeed = validSpeeds.max() ?? 0

        // Elevation — 2 m threshold filters GPS noise
        var gain: Double = 0
        var loss: Double = 0
        let vertAccurate = points.filter { $0.verticalAccuracy >= 0 && $0.verticalAccuracy <= 15 }
        if vertAccurate.count > 1 {
            for i in 1..<vertAccurate.count {
                let diff = vertAccurate[i].altitude - vertAccurate[i-1].altitude
                if diff > 2 { gain += diff }
                else if diff < -2 { loss += abs(diff) }
            }
        }

        // Calories: MET × 70 kg default × hours
        let hours = end.timeIntervalSince(start) / 3600
        let avgMPH = avgSpeed * 2.23694
        let met: Double
        switch avgMPH {
        case ..<10: met = 6.0
        case 10..<12: met = 8.0
        case 12..<15: met = 10.0
        default: met = 12.0
        }
        let calories = met * 70.0 * hours

        return RideSession(
            id: UUID(),
            startDate: start,
            endDate: end,
            trackPoints: accurate,
            distanceMeters: totalDistance,
            avgSpeedMPS: avgSpeed,
            maxSpeedMPS: maxSpeed,
            elevationGainMeters: gain,
            elevationLossMeters: loss,
            estimatedCalories: calories
        )
    }
}
