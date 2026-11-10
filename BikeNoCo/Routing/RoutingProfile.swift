import Foundation

struct RoutingProfile: Sendable {
    var facilityMultipliers: [FacilityType: Double]
    var osmClassMultipliers: [OSMHighwayClass: Double]
    var syntheticAttachmentMultiplier: Double
    /// Fallback for connector edges without a class (should not happen for OSM edges).
    var connectorMultiplier: Double
    var ltsMultipliers: [Int: Double]
    var maxLTS: Int?
    var avoidNaturalSurface: Bool
    var maxSnapMeters: Double
    /// When true, non-trail edges cost ×`preferTrailsNonTrailMultiplier` during A*.
    /// Preferred trail: ArcGIS paved multiuse trail, OSM cycleway / path.
    var preferTrails: Bool

    /// Extra cost applied to non-trail edges when `preferTrails` is on.
    static let preferTrailsNonTrailMultiplier: Double = 1.4

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
        osmClassMultipliers: [
            .cycleway: 1.2,
            .path: 1.2,
            .track: 1.2,
            .footway: 1.4,
            .pedestrian: 1.4,
            .residential: 2.0,
            .livingStreet: 2.0,
            .unclassified: 2.2,
            .service: 2.2,
            .tertiary: 3.0,
            .secondary: 4.0,
            .primary: 6.0
        ],
        syntheticAttachmentMultiplier: 1.0,
        connectorMultiplier: 2.5,
        ltsMultipliers: [
            3: 1.5,
            4: 3.0
        ],
        maxLTS: nil,
        avoidNaturalSurface: false,
        // Walking distance onto the network; generous enough for residential blocks
        // and Simulator long-presses that miss the polyline by a bit.
        maxSnapMeters: 300,
        preferTrails: false
    )

    /// Smallest facility/connector multiplier in the profile (for an admissible A* heuristic).
    var minimumMultiplier: Double {
        var values = Array(facilityMultipliers.values)
        values.append(contentsOf: osmClassMultipliers.values)
        values.append(syntheticAttachmentMultiplier)
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
            if let osmClass = edge.osmClass {
                baseMultiplier = osmClassMultipliers[osmClass] ?? connectorMultiplier
            } else {
                baseMultiplier = syntheticAttachmentMultiplier
            }
        } else {
            baseMultiplier = facilityMultipliers[edge.facilityType] ?? 1.5
        }

        var ltsModifier = 1.0
        if let lts = edge.lts, let modifier = ltsMultipliers[lts] {
            ltsModifier = modifier
        }

        var cost = edge.lengthMeters * baseMultiplier * ltsModifier
        if preferTrails, !Self.isPreferredTrail(edge) {
            cost *= Self.preferTrailsNonTrailMultiplier
        }
        return cost
    }

    /// Paved multiuse trail, or OSM cycleway / path connectors.
    static func isPreferredTrail(_ edge: GraphEdge) -> Bool {
        if edge.isConnector {
            guard let osmClass = edge.osmClass else { return false }
            return osmClass == .cycleway || osmClass == .path
        }
        return edge.facilityType == .pavedTrail
    }

    /// Low-stress mileage rule (spec §5 / task 03b):
    /// - Low-stress: paved/natural trail, ArcGIS LTS ≤ 2, OSM cycleway/path/track,
    ///   OSM footway/pedestrian, OSM residential/living_street, synthetic attachments.
    /// - Not low-stress: OSM service/unclassified, tertiary+, ArcGIS LTS 3+,
    ///   ArcGIS sharrow/no-facility with nil LTS.
    static func isLowStress(_ edge: GraphEdge) -> Bool {
        if edge.isConnector {
            guard let osmClass = edge.osmClass else {
                return true // synthetic attachment
            }
            switch osmClass {
            case .cycleway, .path, .track, .footway, .pedestrian, .residential, .livingStreet:
                return true
            case .service, .unclassified, .tertiary, .secondary, .primary:
                return false
            }
        }

        if edge.facilityType == .pavedTrail || edge.facilityType == .naturalTrail {
            return true
        }
        if let lts = edge.lts {
            return lts <= 2
        }
        // Nil LTS on non-trail ArcGIS (e.g. sharrow / no facilities) is not low-stress.
        return false
    }
}
