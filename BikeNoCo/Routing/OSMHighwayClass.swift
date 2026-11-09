import Foundation

enum OSMHighwayClass: String, Codable, Hashable, Sendable {
    case cycleway
    case path
    case track
    case footway
    case pedestrian
    case residential
    case livingStreet = "living_street"
    case unclassified
    case service
    case tertiary
    case secondary
    case primary

    static func from(_ raw: String) -> OSMHighwayClass? {
        if let direct = OSMHighwayClass(rawValue: raw) {
            return direct
        }
        switch raw {
        case "tertiary_link": return .tertiary
        case "secondary_link": return .secondary
        case "primary_link": return .primary
        default: return nil
        }
    }
}
