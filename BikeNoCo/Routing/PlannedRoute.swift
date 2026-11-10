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

enum TripShape: String, CaseIterable, Equatable, Sendable, Identifiable {
    case oneWay
    case outAndBack
    case loop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneWay: return "One way"
        case .outAndBack: return "Out & back"
        case .loop: return "Loop"
        }
    }
}

/// One segment of a multi-leg trip (outbound, return, or a future via-leg).
struct RouteLeg: Equatable, Sendable {
    /// Inclusive start index into `PlannedRoute.edges`.
    let edgeStartIndex: Int
    let edgeCount: Int
    let distanceMeters: Double
    let endCoordinate: CLLocationCoordinate2D
    /// Optional label for the waypoint at the end of this leg (e.g. via-point street).
    let waypointLabel: String?

    var edgeEndIndex: Int { edgeStartIndex + edgeCount }

    static func == (lhs: RouteLeg, rhs: RouteLeg) -> Bool {
        lhs.edgeStartIndex == rhs.edgeStartIndex
            && lhs.edgeCount == rhs.edgeCount
            && abs(lhs.distanceMeters - rhs.distanceMeters) < 0.01
            && abs(lhs.endCoordinate.latitude - rhs.endCoordinate.latitude) < 1e-8
            && abs(lhs.endCoordinate.longitude - rhs.endCoordinate.longitude) < 1e-8
            && lhs.waypointLabel == rhs.waypointLabel
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
    /// Final arrival coordinate. For out & back / loop this is the original origin.
    let destination: CLLocationCoordinate2D
    let tripShape: TripShape
    /// Ordered legs covering `edges`. One-way has a single leg; out & back / loop have two.
    let legs: [RouteLeg]
    /// For loops: fraction of return-leg distance on or near outbound geometry. Nil otherwise.
    let overlapShare: Double?

    /// Outbound length to the via / turnaround. Nil for one-way.
    var outboundDistanceMeters: Double? {
        guard legs.count >= 2 else { return nil }
        return legs[0].distanceMeters
    }

    /// Number of edges in the first leg. Nil for one-way with a single undifferentiated list
    /// when we still want "all edges" — for multi-leg trips this is the outbound count.
    var outboundEdgeCount: Int? {
        guard legs.count >= 2 else { return nil }
        return legs[0].edgeCount
    }

    var isOutAndBack: Bool { tripShape == .outAndBack }
    var isLoop: Bool { tripShape == .loop }
    /// True when the trip returns to the origin (out & back or loop).
    var returnsToOrigin: Bool { tripShape != .oneWay }

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
            && lhs.tripShape == rhs.tripShape
            && lhs.legs == rhs.legs
            && optionalClose(lhs.overlapShare, rhs.overlapShare)
    }

    private static func optionalClose(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a - b) < 1e-6
        default: return false
        }
    }

    static func make(
        edges: [GraphEdge],
        coordinates: [CLLocationCoordinate2D],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        tripShape: TripShape = .oneWay,
        legs: [RouteLeg]? = nil,
        overlapShare: Double? = nil
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

        let resolvedLegs: [RouteLeg]
        if let legs, !legs.isEmpty {
            resolvedLegs = legs
        } else {
            let along = polylineLength(coordinates)
            resolvedLegs = [
                RouteLeg(
                    edgeStartIndex: 0,
                    edgeCount: edges.count,
                    distanceMeters: along > 0 ? along : total,
                    endCoordinate: destination,
                    waypointLabel: nil
                )
            ]
        }

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
            tripShape: tripShape,
            legs: resolvedLegs,
            overlapShare: overlapShare
        )
    }

    /// Outbound path followed by the exact reverse back to the origin.
    func asOutAndBack(viaLabel: String? = nil) -> PlannedRoute {
        if tripShape == .outAndBack { return self }
        guard !edges.isEmpty, coordinates.count >= 2 else { return self }

        let maxID = edges.map(\.id).max() ?? 0
        let reversedEdges = edges.reversed().enumerated().map { index, edge in
            edge.reversed(id: maxID + index + 1)
        }
        let returnCoordinates = Array(coordinates.dropLast().reversed())
        let fullCoordinates = coordinates + returnCoordinates
        let outboundAlong = Self.polylineLength(coordinates)
        let returnAlong = Self.polylineLength([coordinates.last!] + returnCoordinates)
        let label = viaLabel ?? dominantNames.first

        let outboundLeg = RouteLeg(
            edgeStartIndex: 0,
            edgeCount: edges.count,
            distanceMeters: outboundAlong,
            endCoordinate: coordinates.last!,
            waypointLabel: label
        )
        let returnLeg = RouteLeg(
            edgeStartIndex: edges.count,
            edgeCount: reversedEdges.count,
            distanceMeters: returnAlong > 0 ? returnAlong : outboundAlong,
            endCoordinate: origin,
            waypointLabel: nil
        )

        return PlannedRoute.make(
            edges: edges + reversedEdges,
            coordinates: fullCoordinates,
            origin: origin,
            destination: origin,
            tripShape: .outAndBack,
            legs: [outboundLeg, returnLeg],
            overlapShare: nil
        )
    }

    /// Join an outbound one-way route with a separately routed return leg (loop).
    static func loop(
        outbound: PlannedRoute,
        returnLeg: PlannedRoute,
        overlapShare: Double,
        viaLabel: String? = nil
    ) -> PlannedRoute {
        joining(
            segments: [outbound, returnLeg],
            origin: outbound.origin,
            destination: outbound.origin,
            tripShape: .loop,
            overlapShare: overlapShare,
            waypointLabels: [viaLabel ?? outbound.dominantNames.first, nil]
        )
    }

    /// Concatenate ordered one-way segments into a multi-leg trip (distance loops, via chains).
    static func joining(
        segments: [PlannedRoute],
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        tripShape: TripShape,
        overlapShare: Double?,
        waypointLabels: [String?]? = nil
    ) -> PlannedRoute {
        precondition(!segments.isEmpty)
        var allEdges: [GraphEdge] = []
        var allCoordinates: [CLLocationCoordinate2D] = []
        var legs: [RouteLeg] = []

        for (index, segment) in segments.enumerated() {
            let segmentCoords: [CLLocationCoordinate2D]
            if allCoordinates.isEmpty {
                segmentCoords = segment.coordinates
            } else if let first = segment.coordinates.first,
                      let last = allCoordinates.last,
                      abs(first.latitude - last.latitude) < 1e-8,
                      abs(first.longitude - last.longitude) < 1e-8 {
                segmentCoords = Array(segment.coordinates.dropFirst())
            } else {
                segmentCoords = segment.coordinates
            }

            let along: Double
            if allCoordinates.isEmpty {
                along = polylineLength(segment.coordinates)
            } else if let bridge = allCoordinates.last {
                along = polylineLength([bridge] + segmentCoords)
            } else {
                along = segment.totalDistanceMeters
            }

            let label: String?
            if let labels = waypointLabels, labels.indices.contains(index) {
                label = labels[index]
            } else {
                label = nil
            }
            let leg = RouteLeg(
                edgeStartIndex: allEdges.count,
                edgeCount: segment.edges.count,
                distanceMeters: along > 0 ? along : segment.totalDistanceMeters,
                endCoordinate: segment.destination,
                waypointLabel: label
            )
            legs.append(leg)
            allEdges.append(contentsOf: segment.edges)
            allCoordinates.append(contentsOf: segmentCoords)
        }

        return PlannedRoute.make(
            edges: allEdges,
            coordinates: allCoordinates,
            origin: origin,
            destination: destination,
            tripShape: tripShape,
            legs: legs,
            overlapShare: overlapShare
        )
    }

    /// Paved + natural trail share of total distance.
    var trailShare: Double {
        let trail = (distanceByFacility[.pavedTrail] ?? 0)
            + (distanceByFacility[.naturalTrail] ?? 0)
        return totalDistanceMeters > 0 ? trail / totalDistanceMeters : 0
    }

    static func polylineLength(_ coordinates: [CLLocationCoordinate2D]) -> Double {
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

    /// Coordinate of the via / turnaround (end of the first leg).
    var turnaroundCoordinate: CLLocationCoordinate2D? {
        guard returnsToOrigin, let outbound = outboundDistanceMeters else { return nil }
        return PolylineSlicer.coordinate(at: outbound, along: coordinates) ?? legs.first?.endCoordinate
    }
}
