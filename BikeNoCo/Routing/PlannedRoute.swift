import Foundation
import CoreLocation

enum RoutingError: Error, Equatable, Sendable {
    case originTooFar
    case destinationTooFar
    case noPath(hint: String?)

    var friendlyMessage: String {
        switch self {
        case .originTooFar:
            return "You're too far from the bike network to start a route. Move closer to a trail or bike lane."
        case .destinationTooFar:
            return "That destination is too far from the bike network (more than 150 m from any trail or bike lane)."
        case .noPath(let hint):
            if let hint, !hint.isEmpty {
                return hint
            }
            return "Couldn't find a bike route between those points on the current network."
        }
    }
}

struct PlannedRoute: Equatable {
    let edges: [GraphEdge]
    let coordinates: [CLLocationCoordinate2D]
    let totalDistanceMeters: Double
    let distanceByFacility: [FacilityType: Double]
    let lowStressShare: Double
    let connectorShare: Double
    let dominantNames: [String]
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D

    static func == (lhs: PlannedRoute, rhs: PlannedRoute) -> Bool {
        lhs.edges.map(\.id) == rhs.edges.map(\.id)
            && lhs.totalDistanceMeters == rhs.totalDistanceMeters
            && lhs.lowStressShare == rhs.lowStressShare
            && lhs.connectorShare == rhs.connectorShare
            && lhs.dominantNames == rhs.dominantNames
            && lhs.origin.latitude == rhs.origin.latitude
            && lhs.origin.longitude == rhs.origin.longitude
            && lhs.destination.latitude == rhs.destination.latitude
            && lhs.destination.longitude == rhs.destination.longitude
    }

    static func make(
        edges: [GraphEdge],
        coordinates: [CLLocationCoordinate2D],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> PlannedRoute {
        var distanceByFacility: [FacilityType: Double] = [:]
        var nameDistance: [String: Double] = [:]
        var total = 0.0
        var lowStress = 0.0
        var connector = 0.0

        for edge in edges {
            total += edge.lengthMeters
            distanceByFacility[edge.facilityType, default: 0] += edge.lengthMeters
            if edge.isConnector {
                connector += edge.lengthMeters
            }
            if RoutingProfile.isLowStress(edge) {
                lowStress += edge.lengthMeters
            }
            let trimmed = edge.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                nameDistance[trimmed, default: 0] += edge.lengthMeters
            }
        }

        let dominantNames = nameDistance
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(3)
            .map(\.key)

        return PlannedRoute(
            edges: edges,
            coordinates: coordinates,
            totalDistanceMeters: total,
            distanceByFacility: distanceByFacility,
            lowStressShare: total > 0 ? lowStress / total : 0,
            connectorShare: total > 0 ? connector / total : 0,
            dominantNames: Array(dominantNames),
            origin: origin,
            destination: destination
        )
    }
}
