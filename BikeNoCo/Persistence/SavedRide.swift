import Foundation
import SwiftData
import CoreLocation

@Model
final class SavedRide {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var endDate: Date
    var distanceMeters: Double
    var avgSpeedMPS: Double
    var maxSpeedMPS: Double
    var elevationGainMeters: Double
    var elevationLossMeters: Double
    var estimatedCalories: Double
    var movingDuration: TimeInterval
    var name: String?
    var wasNavigated: Bool
    var trackData: Data
    var route: SavedRoute?

    init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        distanceMeters: Double,
        avgSpeedMPS: Double,
        maxSpeedMPS: Double,
        elevationGainMeters: Double,
        elevationLossMeters: Double,
        estimatedCalories: Double,
        movingDuration: TimeInterval,
        name: String? = nil,
        wasNavigated: Bool = false,
        trackData: Data,
        route: SavedRoute? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.distanceMeters = distanceMeters
        self.avgSpeedMPS = avgSpeedMPS
        self.maxSpeedMPS = maxSpeedMPS
        self.elevationGainMeters = elevationGainMeters
        self.elevationLossMeters = elevationLossMeters
        self.estimatedCalories = estimatedCalories
        self.movingDuration = movingDuration
        self.name = name
        self.wasNavigated = wasNavigated
        self.trackData = trackData
        self.route = route
    }

    convenience init(session: RideSession, wasNavigated: Bool = false, route: SavedRoute? = nil) throws {
        self.init(
            id: session.id,
            startDate: session.startDate,
            endDate: session.endDate,
            distanceMeters: session.distanceMeters,
            avgSpeedMPS: session.avgSpeedMPS,
            maxSpeedMPS: session.maxSpeedMPS,
            elevationGainMeters: session.elevationGainMeters,
            elevationLossMeters: session.elevationLossMeters,
            estimatedCalories: session.estimatedCalories,
            movingDuration: session.movingDuration,
            wasNavigated: wasNavigated,
            trackData: try TrackCodec.encode(session.trackPoints),
            route: route
        )
    }

    func toSession() throws -> RideSession {
        let points = try TrackCodec.decode(trackData)
        return RideSession(
            id: id,
            startDate: startDate,
            endDate: endDate,
            trackPoints: points,
            distanceMeters: distanceMeters,
            avgSpeedMPS: avgSpeedMPS,
            maxSpeedMPS: maxSpeedMPS,
            elevationGainMeters: elevationGainMeters,
            elevationLossMeters: elevationLossMeters,
            estimatedCalories: estimatedCalories,
            movingDuration: movingDuration
        )
    }

    var distanceMiles: Double { distanceMeters / 1609.344 }
    var avgSpeedMPH: Double { avgSpeedMPS * 2.23694 }
}
