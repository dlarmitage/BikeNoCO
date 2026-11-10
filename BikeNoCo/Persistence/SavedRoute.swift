import Foundation
import SwiftData
import CoreLocation

@Model
final class SavedRoute {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdDate: Date
    var waypointsData: Data
    var totalDistanceMeters: Double
    var lowStressShare: Double
    var notes: String?
    var sourceRideID: UUID?

    @Relationship(deleteRule: .nullify, inverse: \SavedRide.route)
    var rides: [SavedRide]

    init(
        id: UUID = UUID(),
        name: String,
        createdDate: Date = Date(),
        waypoints: [CLLocationCoordinate2D],
        totalDistanceMeters: Double,
        lowStressShare: Double,
        notes: String? = nil,
        sourceRideID: UUID? = nil,
        rides: [SavedRide] = []
    ) throws {
        self.id = id
        self.name = name
        self.createdDate = createdDate
        self.waypointsData = try CoordinateCodec.encode(waypoints)
        self.totalDistanceMeters = totalDistanceMeters
        self.lowStressShare = lowStressShare
        self.notes = notes
        self.sourceRideID = sourceRideID
        self.rides = rides
    }

    var waypoints: [CLLocationCoordinate2D] {
        get { (try? CoordinateCodec.decode(waypointsData)) ?? [] }
        set { waypointsData = (try? CoordinateCodec.encode(newValue)) ?? Data() }
    }

    var distanceMiles: Double { totalDistanceMeters / 1609.344 }

    var timesRidden: Int { rides.count }

    /// Fastest moving duration among linked rides, if any.
    var bestMovingDuration: TimeInterval? {
        rides.map(\.movingDuration).min()
    }

    func isPersonalBest(_ ride: SavedRide) -> Bool {
        guard let best = bestMovingDuration else { return false }
        return abs(ride.movingDuration - best) < 0.5
    }

    /// 1-based ordinal of this ride among linked rides ordered by start date.
    func rideOrdinal(for ride: SavedRide) -> Int? {
        let ordered = rides.sorted { $0.startDate < $1.startDate }
        guard let index = ordered.firstIndex(where: { $0.id == ride.id }) else { return nil }
        return index + 1
    }
}
