import Foundation

struct RoutingProfile: Sendable {
    var facilityMultipliers: [FacilityType: Double]
    var connectorMultiplier: Double
    var ltsMultipliers: [Int: Double]
    var maxLTS: Int?
    var avoidNaturalSurface: Bool
    var maxSnapMeters: Double

    static let `default` = RoutingProfile(
        facilityMultipliers: [
            .pavedTrail: 0.8,
            .separatedBikeLane: 0.85,
            .bufferedBikeLane: 0.95,
            .bikeLane: 1.0,
            .sidepath: 1.0,
            .advisoryBikeLane: 1.1,
            .sharrow: 1.4,
            .naturalTrail: 1.5,
            .unclassified: 1.5,
            .noBikeFacilities: 2.0,
            .recommendedRide: 10.0
        ],
        connectorMultiplier: 2.5,
        ltsMultipliers: [
            3: 1.5,
            4: 3.0
        ],
        maxLTS: nil,
        avoidNaturalSurface: false,
        maxSnapMeters: 150
    )

    /// Smallest facility/connector multiplier in the profile (for an admissible A* heuristic).
    var minimumMultiplier: Double {
        var values = Array(facilityMultipliers.values)
        values.append(connectorMultiplier)
        return values.min() ?? 1.0
    }

    /// Weighted traversal cost, or `nil` if the edge is disallowed by this profile.
    func cost(for edge: GraphEdge) -> Double? {
        if avoidNaturalSurface, edge.facilityType == .naturalTrail {
            return nil
        }
        if let maxLTS, let lts = edge.lts, lts > maxLTS {
            return nil
        }

        let baseMultiplier: Double
        if edge.isConnector {
            baseMultiplier = connectorMultiplier
        } else {
            baseMultiplier = facilityMultipliers[edge.facilityType] ?? 1.5
        }

        var ltsModifier = 1.0
        if let lts = edge.lts, let modifier = ltsMultipliers[lts] {
            ltsModifier = modifier
        }

        return edge.lengthMeters * baseMultiplier * ltsModifier
    }

    static func isLowStress(_ edge: GraphEdge) -> Bool {
        if edge.facilityType == .pavedTrail || edge.facilityType == .naturalTrail {
            return true
        }
        if let lts = edge.lts, lts <= 2 {
            return true
        }
        return false
    }
}
