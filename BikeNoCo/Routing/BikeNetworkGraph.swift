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
