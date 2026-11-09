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
        osmClass: OSMHighwayClass? = nil
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
    }
}

struct BikeNetworkGraphBuildResult {
    let graph: BikeNetworkGraph
    let crossingsConsidered: Int
    let crossingsJoined: Int
    let osmEdgesLoaded: Int
    let osmEdgesKept: Int
    let attachmentEdgeCount: Int
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
