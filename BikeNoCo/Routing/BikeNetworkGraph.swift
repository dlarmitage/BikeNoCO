import Foundation
import CoreLocation

struct GraphNode {
    let id: Int
    let coordinate: CLLocationCoordinate2D
}

struct GraphEdge {
    let id: Int
    let fromID: Int
    let toID: Int
    let lengthMeters: Double
    let geometry: [CLLocationCoordinate2D]
    let facilityType: FacilityType
    let lts: Int?
    let name: String
    let sourceRouteID: UUID
    let isConnector: Bool
    /// Present for OSM street connectors; nil for ArcGIS infrastructure and synthetic attachments.
    let osmClass: OSMHighwayClass?
    /// Stable ArcGIS object id when known (not the ephemeral `BikeRoute.id` UUID).
    let sourceObjectId: Int?
    let sourceLayer: String?

    init(
        id: Int,
        fromID: Int,
        toID: Int,
        lengthMeters: Double,
        geometry: [CLLocationCoordinate2D],
        facilityType: FacilityType,
        lts: Int?,
        name: String,
        sourceRouteID: UUID,
        isConnector: Bool,
        osmClass: OSMHighwayClass? = nil,
        sourceObjectId: Int? = nil,
        sourceLayer: String? = nil
    ) {
        self.id = id
        self.fromID = fromID
        self.toID = toID
        self.lengthMeters = lengthMeters
        self.geometry = geometry
        self.facilityType = facilityType
        self.lts = lts
        self.name = name
        self.sourceRouteID = sourceRouteID
        self.isConnector = isConnector
        self.osmClass = osmClass
        self.sourceObjectId = sourceObjectId
        self.sourceLayer = sourceLayer
    }

    /// Same edge traversed in the opposite direction (for round-trip return legs).
    func reversed(id: Int) -> GraphEdge {
        GraphEdge(
            id: id,
            fromID: toID,
            toID: fromID,
            lengthMeters: lengthMeters,
            geometry: Array(geometry.reversed()),
            facilityType: facilityType,
            lts: lts,
            name: name,
            sourceRouteID: sourceRouteID,
            isConnector: isConnector,
            osmClass: osmClass,
            sourceObjectId: sourceObjectId,
            sourceLayer: sourceLayer
        )
    }
}

struct GraphBuildTiming: Equatable {
    var osmDecode: Double = 0
    var arcgisBuild: Double = 0
    var crossingResolution: Double = 0
    var conflation: Double = 0
    var osmInsert: Double = 0
    var attachment: Double = 0
    var pruning: Double = 0
    var cacheWrite: Double = 0
    var cacheRead: Double = 0
    var other: Double = 0
    /// Wall-clock for the full rebuild when stages overlap (preferred for the <2s target).
    var wallClock: Double = 0

    var total: Double {
        if wallClock > 0 { return wallClock }
        return osmDecode + arcgisBuild + crossingResolution + conflation + osmInsert
            + attachment + pruning + cacheWrite + cacheRead + other
    }

    var summary: String {
        """
        [BikeNoCo Graph] stage timings (s):
          osmDecode=\(fmt(osmDecode))  arcgisBuild=\(fmt(arcgisBuild))  crossings=\(fmt(crossingResolution))
          conflation=\(fmt(conflation))  osmInsert=\(fmt(osmInsert))  attachment=\(fmt(attachment))
          pruning=\(fmt(pruning))  other=\(fmt(other))  total=\(fmt(total))
        """
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

struct BikeNetworkGraphBuildResult {
    let graph: BikeNetworkGraph
    let crossingsConsidered: Int
    let crossingsJoined: Int
    let osmEdgesLoaded: Int
    let osmEdgesKept: Int
    let attachmentEdgeCount: Int
    let componentsAfterPrune: Int
    let largestComponentShareAfterPrune: Double
    var timing: GraphBuildTiming
}

struct BikeNetworkGraph {
    let nodesByID: [Int: GraphNode]
    let edgesByID: [Int: GraphEdge]
    /// Node id → incident edge ids.
    let adjacency: [Int: [Int]]
    let projection: LocalProjection

    var nodes: [GraphNode] {
        nodesByID.values.sorted { $0.id < $1.id }
    }

    var edges: [GraphEdge] {
        edgesByID.values.sorted { $0.id < $1.id }
    }

    func node(id: Int) -> GraphNode? {
        nodesByID[id]
    }

    func edge(id: Int) -> GraphEdge? {
        edgesByID[id]
    }
}
