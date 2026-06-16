import MapKit

enum FacilityType: String, CaseIterable, Codable, Hashable {
    case bikeLane = "Bike Lane"
    case bufferedBikeLane = "Buffered Bike Lane"
    case separatedBikeLane = "Separated Bike Lane"
    case sharrow = "Sharrow"
    case sidepath = "Sidepath"
    case advisoryBikeLane = "Advisory Bike Lane"
    case pavedTrail = "Paved Multiuse Trail"
    case naturalTrail = "Natural Surface Trail"
    case noBikeFacilities = "No Bike Facilities"
    case unclassified = "Unclassified"
    case recommendedRide = "Recommended Road Ride"

    static func from(_ string: String?) -> FacilityType {
        guard let string, !string.isEmpty else { return .unclassified }
        return FacilityType(rawValue: string) ?? .unclassified
    }

    var color: UIColor {
        switch self {
        case .bikeLane:           return UIColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1) // green
        case .bufferedBikeLane:   return UIColor(red: 0.20, green: 0.60, blue: 0.86, alpha: 1) // blue
        case .separatedBikeLane:  return UIColor(red: 0.11, green: 0.37, blue: 0.63, alpha: 1) // dark blue
        case .sharrow:            return UIColor(red: 0.90, green: 0.49, blue: 0.13, alpha: 1) // orange
        case .sidepath:           return UIColor(red: 0.56, green: 0.27, blue: 0.68, alpha: 1) // purple
        case .advisoryBikeLane:   return UIColor(red: 0.85, green: 0.65, blue: 0.02, alpha: 1) // gold
        case .pavedTrail:         return UIColor(red: 0.00, green: 0.75, blue: 0.75, alpha: 1) // teal
        case .naturalTrail:       return UIColor(red: 0.60, green: 0.40, blue: 0.20, alpha: 1) // brown
        case .noBikeFacilities:   return UIColor(red: 0.58, green: 0.65, blue: 0.65, alpha: 1) // gray
        case .unclassified:       return UIColor(red: 0.70, green: 0.70, blue: 0.70, alpha: 1) // light gray
        case .recommendedRide:    return UIColor(red: 0.88, green: 0.25, blue: 0.22, alpha: 0.80) // muted coral-red
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .recommendedRide: return 3.5
        case .separatedBikeLane, .pavedTrail: return 4
        case .bikeLane, .bufferedBikeLane: return 3
        default: return 2
        }
    }

    var displayName: String {
        switch self {
        case .sharrow: return "Shared Bike Lane"
        default: return rawValue
        }
    }

    var isDashed: Bool {
        self == .recommendedRide
    }
}

struct BikeRoute: Identifiable, Equatable {
    static func == (lhs: BikeRoute, rhs: BikeRoute) -> Bool { lhs.id == rhs.id }
    let id: UUID
    let objectId: Int
    let streetName: String
    let facilityType: FacilityType
    let lts: Int?
    let mapSymbolClass: String?
    let bikewayName: String?
    let speedLimit: Int?
    let paths: [[CLLocationCoordinate2D]]
    let routeDistance: Double?
    let elevationGain: Double?
    let routeDescription: String?

    init(
        id: UUID, objectId: Int, streetName: String, facilityType: FacilityType,
        lts: Int?, mapSymbolClass: String?, bikewayName: String?, speedLimit: Int?,
        paths: [[CLLocationCoordinate2D]],
        routeDistance: Double? = nil, elevationGain: Double? = nil, routeDescription: String? = nil
    ) {
        self.id = id
        self.objectId = objectId
        self.streetName = streetName
        self.facilityType = facilityType
        self.lts = lts
        self.mapSymbolClass = mapSymbolClass
        self.bikewayName = bikewayName
        self.speedLimit = speedLimit
        self.paths = paths
        self.routeDistance = routeDistance
        self.elevationGain = elevationGain
        self.routeDescription = routeDescription
    }

    var formattedDistance: String? {
        guard let d = routeDistance else { return nil }
        return String(format: "%.1f mi", d / 1609.344)
    }

    var formattedElevationGain: String? {
        guard let e = elevationGain else { return nil }
        return String(format: "%.0f ft", e * 3.28084)
    }

    var stressLabel: String {
        switch lts {
        case 1: return "Very Low Stress"
        case 2: return "Low Stress"
        case 3: return "Moderate Stress"
        case 4: return "High Stress"
        default: return "Unknown"
        }
    }

    var stressColor: UIColor {
        switch lts {
        case 1: return UIColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1)
        case 2: return UIColor(red: 0.95, green: 0.77, blue: 0.06, alpha: 1)
        case 3: return UIColor(red: 0.90, green: 0.49, blue: 0.13, alpha: 1)
        case 4: return UIColor(red: 0.91, green: 0.30, blue: 0.24, alpha: 1)
        default: return .gray
        }
    }
}

