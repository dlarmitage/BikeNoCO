import Foundation
import CoreLocation

enum ManeuverType: String, Equatable, Sendable {
    case depart
    case `continue`
    case slightLeft
    case slightRight
    case left
    case right
    case sharpLeft
    case sharpRight
    case uTurn
    case arrive

    var systemImage: String {
        switch self {
        case .depart: return "figure.walk.departure"
        case .continue: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .sharpLeft: return "arrow.uturn.left"
        case .sharpRight: return "arrow.uturn.right"
        case .uTurn: return "arrow.uturn.backward"
        case .arrive: return "flag.checkered"
        }
    }
}

struct Maneuver: Equatable, Identifiable, Sendable {
    let id: UUID
    let type: ManeuverType
    let coordinate: CLLocationCoordinate2D
    /// Meters from the route origin to this maneuver.
    let distanceAlongRoute: Double
    /// Meters from this maneuver to the next (0 for arrive).
    let distanceToNext: Double
    let streetName: String?
    let instruction: String
    /// Signed turn angle in degrees (negative = left). Nil for depart/arrive.
    let turnAngleDegrees: Double?

    init(
        id: UUID = UUID(),
        type: ManeuverType,
        coordinate: CLLocationCoordinate2D,
        distanceAlongRoute: Double,
        distanceToNext: Double,
        streetName: String?,
        instruction: String,
        turnAngleDegrees: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.coordinate = coordinate
        self.distanceAlongRoute = distanceAlongRoute
        self.distanceToNext = distanceToNext
        self.streetName = streetName
        self.instruction = instruction
        self.turnAngleDegrees = turnAngleDegrees
    }

    static func == (lhs: Maneuver, rhs: Maneuver) -> Bool {
        lhs.type == rhs.type
            && abs(lhs.distanceAlongRoute - rhs.distanceAlongRoute) < 0.01
            && abs(lhs.distanceToNext - rhs.distanceToNext) < 0.01
            && lhs.streetName == rhs.streetName
            && lhs.instruction == rhs.instruction
            && abs(lhs.coordinate.latitude - rhs.coordinate.latitude) < 1e-8
            && abs(lhs.coordinate.longitude - rhs.coordinate.longitude) < 1e-8
            && optionalAngleEqual(lhs.turnAngleDegrees, rhs.turnAngleDegrees)
    }

    private static func optionalAngleEqual(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a - b) < 0.1
        default: return false
        }
    }
}
