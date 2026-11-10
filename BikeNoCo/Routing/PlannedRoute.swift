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
            return "That destination is too far from the bike network (more than 300 m from any trail or bike lane)."
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
    /// Final arrival coordinate. For a round trip this is the original origin.
    let destination: CLLocationCoordinate2D
    /// When true, the route is outbound + exact reverse back to origin.
    let isRoundTrip: Bool
    /// Outbound length to the turnaround. Nil when not a round trip.
    let outboundDistanceMeters: Double?
    /// Number of edges in the outbound leg. Nil when not a round trip.
    let outboundEdgeCount: Int?

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
            && lhs.isRoundTrip == rhs.isRoundTrip
            && lhs.outboundDistanceMeters == rhs.outboundDistanceMeters
            && lhs.outboundEdgeCount == rhs.outboundEdgeCount
    }

    static func make(
        edges: [GraphEdge],
        coordinates: [CLLocationCoordinate2D],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        isRoundTrip: Bool = false,
        outboundDistanceMeters: Double? = nil,
        outboundEdgeCount: Int? = nil
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
            destination: destination,
            isRoundTrip: isRoundTrip,
            outboundDistanceMeters: outboundDistanceMeters,
            outboundEdgeCount: outboundEdgeCount
        )
    }

    /// Outbound path followed by the exact reverse back to the origin.
    func asRoundTrip() -> PlannedRoute {
        if isRoundTrip { return self }
        guard !edges.isEmpty, coordinates.count >= 2 else { return self }

        let maxID = edges.map(\.id).max() ?? 0
        let reversedEdges = edges.reversed().enumerated().map { index, edge in
            edge.reversed(id: maxID + index + 1)
        }
        let returnCoordinates = Array(coordinates.dropLast().reversed())
        let fullCoordinates = coordinates + returnCoordinates
        // Use polyline length so turnaround distance matches RouteProgressTracker.
        let outboundAlong = Self.polylineLength(coordinates)

        return PlannedRoute.make(
            edges: edges + reversedEdges,
            coordinates: fullCoordinates,
            origin: origin,
            destination: origin,
            isRoundTrip: true,
            outboundDistanceMeters: outboundAlong,
            outboundEdgeCount: edges.count
        )
    }

    private static func polylineLength(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        let projection = LocalProjection(
            originLatitude: coordinates[0].latitude,
            originLongitude: coordinates[0].longitude
        )
        let locals = coordinates.map { projection.toLocal($0) }
        var total = 0.0
        for i in 1..<locals.count {
            total += locals[i - 1].distance(to: locals[i])
        }
        return total
    }

    /// Coordinate of the turnaround (original one-way destination).
    var turnaroundCoordinate: CLLocationCoordinate2D? {
        guard isRoundTrip, let outbound = outboundDistanceMeters else { return nil }
        return PolylineSlicer.coordinate(at: outbound, along: coordinates) ?? coordinates[coordinates.count / 2]
    }
}
