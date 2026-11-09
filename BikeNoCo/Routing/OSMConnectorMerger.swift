import Foundation
import CoreLocation

enum OSMConnectorMerger {
    private static let conflationDistanceMeters = 10.0
    private static let conflationLengthFraction = 0.8
    private static let nodeAttachMeters = 15.0
    private static let tAttachMeters = 8.0
    private static let crossingJoinMeters = 10.0
    static func merge(
        arcgis: BikeNetworkGraph,
        connectors: [OSMConnectorEdge]
    ) -> BikeNetworkGraphBuildResult {
        var state = MutableGraph(from: arcgis)
        let osmIndex = OSMNodeIndex(connectors: connectors, projection: arcgis.projection)

        let (crossingsConsidered, crossingsJoined) = resolveAtGradeCrossings(
            state: &state,
            osmIndex: osmIndex
        )

        state.ensureArcGISSegmentGrid()
        let kept = connectors.filter { !shouldConflate($0, against: state) }
        let osmEdgesLoaded = connectors.count
        let osmEdgesKept = kept.count

        var osmNodeToGraph: [Int64: Int] = [:]
        for edge in kept {
            ensureOSMNode(edge.startNodeID, coordinate: edge.coordinates.first, osmIndex: osmIndex, map: &osmNodeToGraph, state: &state)
            ensureOSMNode(edge.endNodeID, coordinate: edge.coordinates.last, osmIndex: osmIndex, map: &osmNodeToGraph, state: &state)
        }

        for edge in kept {
            guard let fromID = osmNodeToGraph[edge.startNodeID],
                  let toID = osmNodeToGraph[edge.endNodeID],
                  edge.coordinates.count >= 2 else { continue }
            let local = edge.coordinates.map { state.projection.toLocal($0) }
            let length = polylineLength(local)
            guard length > 0.05 else { continue }
            state.addEdge(
                fromID: fromID,
                toID: toID,
                geometry: edge.coordinates,
                lengthMeters: length,
                name: edge.name ?? "",
                isConnector: true,
                osmClass: edge.highwayClass
            )
        }

        let attachments = attachNetworks(state: &state, osmIndex: osmIndex, osmNodeToGraph: osmNodeToGraph)

        return BikeNetworkGraphBuildResult(
            graph: state.freeze(),
            crossingsConsidered: crossingsConsidered,
            crossingsJoined: crossingsJoined,
            osmEdgesLoaded: osmEdgesLoaded,
            osmEdgesKept: osmEdgesKept,
            attachmentEdgeCount: attachments
        )
    }

    // MARK: - Crossing resolution

    private static func resolveAtGradeCrossings(
        state: inout MutableGraph,
        osmIndex: OSMNodeIndex
    ) -> (considered: Int, joined: Int) {
        let crossings = findCrossings(in: state)
        var joined = 0

        // Process farthest-from-endpoint crossings first; re-find after mutations is expensive,
        // so join using original geometry snapshots and skip edges that were already replaced.
        var removedEdgeIDs: Set<Int> = []

        for crossing in crossings {
            if removedEdgeIDs.contains(crossing.edgeAID) || removedEdgeIDs.contains(crossing.edgeBID) {
                continue
            }
            guard let candidate = osmIndex.bestAtGradeJunction(near: crossing.point, radius: crossingJoinMeters) else {
                continue
            }

            guard let edgeA = state.edgesByID[crossing.edgeAID],
                  let edgeB = state.edgesByID[crossing.edgeBID] else { continue }

            let sharedNodeID = state.addNode(at: crossing.point)
            // Prefer the OSM junction coordinate if very close — keeps attachment consistent.
            if candidate.local.distance(to: crossing.point) <= crossingJoinMeters {
                state.nodesByID[sharedNodeID] = GraphNode(
                    id: sharedNodeID,
                    coordinate: state.projection.toCoordinate(crossing.point)
                )
                state.nodeLocal[sharedNodeID] = crossing.point
            }

            if splitEdge(edgeA, at: crossing.point, sharedNodeID: sharedNodeID, state: &state) {
                removedEdgeIDs.insert(edgeA.id)
            }
            if splitEdge(edgeB, at: crossing.point, sharedNodeID: sharedNodeID, state: &state) {
                removedEdgeIDs.insert(edgeB.id)
            }
            joined += 1
        }

        return (crossings.count, joined)
    }

    private struct Crossing {
        let edgeAID: Int
        let edgeBID: Int
        let point: LocalPoint
    }

    private static func findCrossings(in state: MutableGraph) -> [Crossing] {
        var grid = SpatialGrid<EdgeSeg>(cellSize: 25)
        var localGeometry: [Int: [LocalPoint]] = [:]
        for edge in state.edgesByID.values where !edge.isConnector {
            let points = edge.geometry.map { state.projection.toLocal($0) }
            localGeometry[edge.id] = points
            for i in 0..<(points.count - 1) {
                grid.insertSegment(id: EdgeSeg(edgeID: edge.id, segmentIndex: i), from: points[i], to: points[i + 1])
            }
        }

        var results: [Crossing] = []
        var seen: Set<EdgePairKey> = []
        for edge in state.edgesByID.values where !edge.isConnector {
            guard let points = localGeometry[edge.id] else { continue }
            for i in 0..<(points.count - 1) {
                let a1 = points[i]
                let a2 = points[i + 1]
                for candidate in grid.segments(alongFrom: a1, to: a2) {
                    if candidate.id.edgeID <= edge.id { continue }
                    guard let other = state.edgesByID[candidate.id.edgeID], !other.isConnector else { continue }
                    if sharesNode(edge, other) { continue }
                    let key = EdgePairKey(a: edge.id, b: other.id)
                    if seen.contains(key) { continue }
                    if let hit = LocalProjection.properIntersection(a1: a1, a2: a2, b1: candidate.a, b2: candidate.b) {
                        seen.insert(key)
                        results.append(Crossing(edgeAID: edge.id, edgeBID: other.id, point: hit))
                    }
                }
            }
        }
        return results
    }

    @discardableResult
    private static func splitEdge(
        _ edge: GraphEdge,
        at point: LocalPoint,
        sharedNodeID: Int,
        state: inout MutableGraph
    ) -> Bool {
        let local = edge.geometry.map { state.projection.toLocal($0) }
        guard let projection = projectOntoPolyline(point, points: local) else { return false }

        let leftGeomLocal = Array(local.prefix(projection.vertexIndex + 1)) + [point]
        let rightGeomLocal = [point] + Array(local.suffix(from: projection.vertexIndex + 1))
        let leftCoords = collapseCoordinates(leftGeomLocal.map { state.projection.toCoordinate($0) })
        let rightCoords = collapseCoordinates(rightGeomLocal.map { state.projection.toCoordinate($0) })
        let leftLen = polylineLength(leftGeomLocal)
        let rightLen = polylineLength(rightGeomLocal)

        state.removeEdge(id: edge.id)

        if leftLen > 0.05, leftCoords.count >= 2 {
            state.addEdge(
                fromID: edge.fromID,
                toID: sharedNodeID,
                geometry: leftCoords,
                lengthMeters: leftLen,
                name: edge.name,
                facilityType: edge.facilityType,
                lts: edge.lts,
                sourceRouteID: edge.sourceRouteID,
                isConnector: edge.isConnector,
                osmClass: edge.osmClass
            )
        }
        if rightLen > 0.05, rightCoords.count >= 2 {
            state.addEdge(
                fromID: sharedNodeID,
                toID: edge.toID,
                geometry: rightCoords,
                lengthMeters: rightLen,
                name: edge.name,
                facilityType: edge.facilityType,
                lts: edge.lts,
                sourceRouteID: edge.sourceRouteID,
                isConnector: edge.isConnector,
                osmClass: edge.osmClass
            )
        }
        return true
    }

    // MARK: - Conflation

    private static func shouldConflate(_ edge: OSMConnectorEdge, against state: MutableGraph) -> Bool {
        let local = edge.coordinates.map { state.projection.toLocal($0) }
        guard local.count >= 2 else { return true }
        let total = polylineLength(local)
        guard total > 0.5 else { return false }

        var covered = 0.0
        var traveled = 0.0
        let step = 5.0
        var cursor = 0.0
        while cursor <= total {
            guard let point = pointAlong(local, distance: cursor) else { break }
            if nearestArcGISDistance(point, state: state) <= conflationDistanceMeters {
                let next = min(cursor + step, total)
                covered += next - cursor
            }
            cursor += step
            traveled = cursor
        }
        _ = traveled
        return (covered / total) >= conflationLengthFraction
    }

    private static func nearestArcGISDistance(_ point: LocalPoint, state: MutableGraph) -> Double {
        guard let grid = state.arcGISSegmentGrid else { return .infinity }
        let hits = grid.segments(near: point, radius: conflationDistanceMeters)
        var best = Double.infinity
        for hit in hits {
            best = min(best, point.projected(ontoSegmentFrom: hit.a, to: hit.b).distance)
        }
        return best
    }

    // MARK: - Attachments

    private static func attachNetworks(
        state: inout MutableGraph,
        osmIndex: OSMNodeIndex,
        osmNodeToGraph: [Int64: Int]
    ) -> Int {
        var count = 0
        state.ensureArcGISSegmentGrid()

        // ArcGIS node → nearest eligible OSM node within 15 m
        for node in state.nodesByID.values {
            // Skip nodes that only exist as OSM (heuristic: check if any incident edge is non-connector)
            let incident = state.adjacency[node.id] ?? []
            let hasArcGIS = incident.contains { id in
                state.edgesByID[id]?.isConnector == false
            }
            guard hasArcGIS else { continue }

            let local = state.projection.toLocal(node.coordinate)
            guard let match = osmIndex.nearestAttachableNode(to: local, radius: nodeAttachMeters),
                  let osmGraphID = osmNodeToGraph[match.osmID] else { continue }
            if osmGraphID == node.id { continue }
            if hasDirectEdge(from: node.id, to: osmGraphID, state: state) { continue }

            let length = max(local.distance(to: match.local), 0.1)
            let coords = [node.coordinate, state.projection.toCoordinate(match.local)]
            state.addEdge(
                fromID: node.id,
                toID: osmGraphID,
                geometry: coords,
                lengthMeters: length,
                name: "",
                isConnector: true,
                osmClass: nil
            )
            count += 1
        }

        // OSM node → ArcGIS edge interior T-attachment within 8 m.
        // Collect candidates first, group by edge, then split each edge once.
        state.ensureArcGISSegmentGrid()
        guard let grid = state.arcGISSegmentGrid else { return count }

        var candidates: [(osmGraphID: Int, edgeID: Int, point: LocalPoint, distance: Double)] = []
        for (osmID, graphID) in osmNodeToGraph {
            guard let info = osmIndex.nodes[osmID], info.isAttachable else { continue }
            let hits = grid.segments(near: info.local, radius: tAttachMeters)
            var best: (edgeID: Int, point: LocalPoint, distance: Double)?
            for hit in hits {
                guard let edge = state.edgesByID[hit.id], !edge.isConnector else { continue }
                let projected = info.local.projected(ontoSegmentFrom: hit.a, to: hit.b)
                guard projected.distance <= tAttachMeters else { continue }
                let edgeLocal = edge.geometry.map { state.projection.toLocal($0) }
                guard let along = projectOntoPolyline(projected.point, points: edgeLocal) else { continue }
                if along.distanceAlong <= 1.0 || along.distanceAlong >= (polylineLength(edgeLocal) - 1.0) {
                    continue
                }
                if let current = best, projected.distance >= current.distance { continue }
                best = (edge.id, projected.point, projected.distance)
            }
            if let hit = best {
                candidates.append((graphID, hit.edgeID, hit.point, hit.distance))
            }
        }

        let byEdge = Dictionary(grouping: candidates, by: \.edgeID)
        for (edgeID, group) in byEdge {
            guard let edge = state.edgesByID[edgeID] else { continue }
            // Deduplicate split points that land within 1 m of each other.
            var uniquePoints: [LocalPoint] = []
            var osmLinks: [(osmGraphID: Int, point: LocalPoint)] = []
            for item in group.sorted(by: { $0.distance < $1.distance }) {
                if uniquePoints.contains(where: { $0.distance(to: item.point) < 1.0 }) {
                    // Still link this OSM node to the nearby existing split point later.
                    if let existing = uniquePoints.min(by: { $0.distance(to: item.point) < $1.distance(to: item.point) }) {
                        osmLinks.append((item.osmGraphID, existing))
                    }
                    continue
                }
                uniquePoints.append(item.point)
                osmLinks.append((item.osmGraphID, item.point))
            }

            var pointToNode: [String: Int] = [:]
            func key(_ p: LocalPoint) -> String {
                String(format: "%.2f:%.2f", p.x, p.y)
            }

            // Split successively from the original edge geometry.
            var currentPieces: [(fromID: Int, toID: Int, geometry: [CLLocationCoordinate2D], length: Double)] = [
                (edge.fromID, edge.toID, edge.geometry, edge.lengthMeters)
            ]
            state.removeEdge(id: edge.id)

            for point in uniquePoints {
                var nextPieces: [(fromID: Int, toID: Int, geometry: [CLLocationCoordinate2D], length: Double)] = []
                var placed = false
                for piece in currentPieces {
                    let local = piece.geometry.map { state.projection.toLocal($0) }
                    guard let proj = projectOntoPolyline(point, points: local),
                          proj.distanceAlong > 1.0,
                          proj.distanceAlong < polylineLength(local) - 1.0 else {
                        nextPieces.append(piece)
                        continue
                    }
                    let sharedID = state.addNode(at: point)
                    pointToNode[key(point)] = sharedID
                    let leftLocal = Array(local.prefix(proj.vertexIndex + 1)) + [point]
                    let rightLocal = [point] + Array(local.suffix(from: proj.vertexIndex + 1))
                    let leftCoords = collapseCoordinates(leftLocal.map { state.projection.toCoordinate($0) })
                    let rightCoords = collapseCoordinates(rightLocal.map { state.projection.toCoordinate($0) })
                    nextPieces.append((piece.fromID, sharedID, leftCoords, polylineLength(leftLocal)))
                    nextPieces.append((sharedID, piece.toID, rightCoords, polylineLength(rightLocal)))
                    placed = true
                }
                if !placed {
                    nextPieces = currentPieces
                }
                currentPieces = nextPieces
            }

            for piece in currentPieces where piece.length > 0.05 && piece.geometry.count >= 2 {
                state.addEdge(
                    fromID: piece.fromID,
                    toID: piece.toID,
                    geometry: piece.geometry,
                    lengthMeters: piece.length,
                    name: edge.name,
                    facilityType: edge.facilityType,
                    lts: edge.lts,
                    sourceRouteID: edge.sourceRouteID,
                    isConnector: false,
                    osmClass: nil
                )
            }

            for link in osmLinks {
                let nodeID: Int
                if let existing = pointToNode[key(link.point)] {
                    nodeID = existing
                } else if let near = pointToNode.values.first(where: {
                    guard let local = state.nodeLocal[$0] else { return false }
                    return local.distance(to: link.point) < 1.0
                }) {
                    nodeID = near
                } else {
                    continue
                }
                if hasDirectEdge(from: link.osmGraphID, to: nodeID, state: state) { continue }
                let fromLocal = state.nodeLocal[link.osmGraphID] ?? link.point
                let toLocal = state.nodeLocal[nodeID] ?? link.point
                state.addEdge(
                    fromID: link.osmGraphID,
                    toID: nodeID,
                    geometry: [state.projection.toCoordinate(fromLocal), state.projection.toCoordinate(toLocal)],
                    lengthMeters: max(fromLocal.distance(to: toLocal), 0.1),
                    name: "",
                    isConnector: true,
                    osmClass: nil
                )
                count += 1
            }
        }

        return count
    }

    private static func ensureOSMNode(
        _ osmID: Int64,
        coordinate: CLLocationCoordinate2D?,
        osmIndex: OSMNodeIndex,
        map: inout [Int64: Int],
        state: inout MutableGraph
    ) {
        if map[osmID] != nil { return }
        let local: LocalPoint
        if let known = osmIndex.nodes[osmID]?.local {
            local = known
        } else if let coordinate {
            local = state.projection.toLocal(coordinate)
        } else {
            return
        }
        let id = state.addNode(at: local)
        map[osmID] = id
    }

    private static func hasDirectEdge(from: Int, to: Int, state: MutableGraph) -> Bool {
        for edgeID in state.adjacency[from] ?? [] {
            guard let edge = state.edgesByID[edgeID] else { continue }
            if (edge.fromID == from && edge.toID == to) || (edge.fromID == to && edge.toID == from) {
                return true
            }
        }
        return false
    }

    // MARK: - Geometry helpers

    private static func polylineLength(_ points: [LocalPoint]) -> Double {
        var length = 0.0
        for i in 1..<points.count {
            length += points[i - 1].distance(to: points[i])
        }
        return length
    }

    private static func pointAlong(_ points: [LocalPoint], distance: Double) -> LocalPoint? {
        guard points.count >= 2 else { return points.first }
        var remaining = distance
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let seg = a.distance(to: b)
            if remaining <= seg || i == points.count - 2 {
                let t = seg > 0 ? remaining / seg : 0
                return LocalPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= seg
        }
        return points.last
    }

    private static func projectOntoPolyline(
        _ query: LocalPoint,
        points: [LocalPoint]
    ) -> (point: LocalPoint, distanceAlong: Double, vertexIndex: Int, t: Double)? {
        guard points.count >= 2 else { return nil }
        var bestDistance = Double.infinity
        var bestPoint = points[0]
        var bestAlong = 0.0
        var bestVertex = 0
        var bestT = 0.0
        var traveled = 0.0
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let seg = a.distance(to: b)
            let projected = query.projected(ontoSegmentFrom: a, to: b)
            if projected.distance < bestDistance {
                bestDistance = projected.distance
                bestPoint = projected.point
                bestAlong = traveled + projected.t * seg
                bestVertex = i
                bestT = projected.t
            }
            traveled += seg
        }
        return (bestPoint, bestAlong, bestVertex, bestT)
    }

    private static func collapseCoordinates(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coords {
            if let last = result.last,
               abs(last.latitude - coordinate.latitude) < 1e-10,
               abs(last.longitude - coordinate.longitude) < 1e-10 {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func sharesNode(_ a: GraphEdge, _ b: GraphEdge) -> Bool {
        a.fromID == b.fromID || a.fromID == b.toID || a.toID == b.fromID || a.toID == b.toID
    }

    private struct EdgeSeg: Hashable {
        let edgeID: Int
        let segmentIndex: Int
    }

    private struct EdgePairKey: Hashable {
        let a: Int
        let b: Int
        init(a: Int, b: Int) {
            if a < b {
                self.a = a
                self.b = b
            } else {
                self.a = b
                self.b = a
            }
        }
    }
}

// MARK: - Mutable graph

private struct MutableGraph {
    var nodesByID: [Int: GraphNode]
    var edgesByID: [Int: GraphEdge]
    var adjacency: [Int: [Int]]
    var nodeLocal: [Int: LocalPoint]
    var nextNodeID: Int
    var nextEdgeID: Int
    let projection: LocalProjection
    var arcGISSegmentGrid: SpatialGrid<Int>?

    init(from graph: BikeNetworkGraph) {
        self.nodesByID = graph.nodesByID
        self.edgesByID = graph.edgesByID
        self.adjacency = graph.adjacency
        self.projection = graph.projection
        self.nextNodeID = (graph.nodesByID.keys.max() ?? -1) + 1
        self.nextEdgeID = (graph.edgesByID.keys.max() ?? -1) + 1
        var local: [Int: LocalPoint] = [:]
        for node in graph.nodesByID.values {
            local[node.id] = graph.projection.toLocal(node.coordinate)
        }
        self.nodeLocal = local
    }

    mutating func addNode(at local: LocalPoint) -> Int {
        let id = nextNodeID
        nextNodeID += 1
        nodesByID[id] = GraphNode(id: id, coordinate: projection.toCoordinate(local))
        nodeLocal[id] = local
        return id
    }

    mutating func addEdge(
        fromID: Int,
        toID: Int,
        geometry: [CLLocationCoordinate2D],
        lengthMeters: Double,
        name: String,
        facilityType: FacilityType = .unclassified,
        lts: Int? = nil,
        sourceRouteID: UUID? = nil,
        isConnector: Bool,
        osmClass: OSMHighwayClass?
    ) {
        let id = nextEdgeID
        nextEdgeID += 1
        let edge = GraphEdge(
            id: id,
            fromID: fromID,
            toID: toID,
            lengthMeters: lengthMeters,
            geometry: geometry,
            facilityType: facilityType,
            lts: lts,
            name: name,
            sourceRouteID: sourceRouteID ?? osmConnectorSourceID,
            isConnector: isConnector,
            osmClass: osmClass
        )
        edgesByID[id] = edge
        adjacency[fromID, default: []].append(id)
        if fromID != toID {
            adjacency[toID, default: []].append(id)
        }
        arcGISSegmentGrid = nil
    }

    mutating func removeEdge(id: Int) {
        guard let edge = edgesByID.removeValue(forKey: id) else { return }
        adjacency[edge.fromID] = (adjacency[edge.fromID] ?? []).filter { $0 != id }
        if edge.fromID != edge.toID {
            adjacency[edge.toID] = (adjacency[edge.toID] ?? []).filter { $0 != id }
        }
        arcGISSegmentGrid = nil
    }

    mutating func ensureArcGISSegmentGrid() {
        if arcGISSegmentGrid != nil { return }
        var grid = SpatialGrid<Int>(cellSize: 25)
        for edge in edgesByID.values where !edge.isConnector {
            let points = edge.geometry.map { projection.toLocal($0) }
            for i in 0..<(points.count - 1) {
                grid.insertSegment(id: edge.id, from: points[i], to: points[i + 1])
            }
        }
        arcGISSegmentGrid = grid
    }

    func freeze() -> BikeNetworkGraph {
        BikeNetworkGraph(
            nodesByID: nodesByID,
            edgesByID: edgesByID,
            adjacency: adjacency,
            projection: projection
        )
    }
}

private let osmConnectorSourceID = UUID(uuidString: "A1111111-B222-C333-D444-E55555555555")!

// MARK: - OSM node index

private struct OSMNodeIndex {
    struct NodeInfo {
        let osmID: Int64
        let local: LocalPoint
        let degree: Int
        let onlyGradeSeparated: Bool

        var isAttachable: Bool { !onlyGradeSeparated }
        var isAtGradeJunction: Bool { degree >= 3 && !onlyGradeSeparated }
    }

    let nodes: [Int64: NodeInfo]
    private let pointGrid: SpatialGrid<Int64>

    init(connectors: [OSMConnectorEdge], projection: LocalProjection) {
        var degree: [Int64: Int] = [:]
        var bridgeTunnelOnly: [Int64: Bool] = [:]
        var coordinate: [Int64: CLLocationCoordinate2D] = [:]

        for edge in connectors {
            degree[edge.startNodeID, default: 0] += 1
            degree[edge.endNodeID, default: 0] += 1
            let gradeSeparated = edge.isBridge || edge.isTunnel
            for nid in [edge.startNodeID, edge.endNodeID] {
                if bridgeTunnelOnly[nid] == nil {
                    bridgeTunnelOnly[nid] = gradeSeparated
                } else {
                    bridgeTunnelOnly[nid] = bridgeTunnelOnly[nid]! && gradeSeparated
                }
            }
            if let first = edge.coordinates.first {
                coordinate[edge.startNodeID] = first
            }
            if let last = edge.coordinates.last {
                coordinate[edge.endNodeID] = last
            }
        }

        var nodes: [Int64: NodeInfo] = [:]
        var grid = SpatialGrid<Int64>(cellSize: 25)
        for (osmID, coord) in coordinate {
            let local = projection.toLocal(coord)
            let info = NodeInfo(
                osmID: osmID,
                local: local,
                degree: degree[osmID] ?? 0,
                onlyGradeSeparated: bridgeTunnelOnly[osmID] ?? false
            )
            nodes[osmID] = info
            grid.insertPoint(id: osmID, at: local)
        }
        self.nodes = nodes
        self.pointGrid = grid
    }

    func bestAtGradeJunction(near point: LocalPoint, radius: Double) -> NodeInfo? {
        pointGrid.points(near: point, radius: radius)
            .compactMap { nodes[$0.id] }
            .filter(\.isAtGradeJunction)
            .min(by: { $0.local.distance(to: point) < $1.local.distance(to: point) })
    }

    func nearestAttachableNode(to point: LocalPoint, radius: Double) -> NodeInfo? {
        pointGrid.points(near: point, radius: radius)
            .compactMap { nodes[$0.id] }
            .filter(\.isAttachable)
            .min(by: { $0.local.distance(to: point) < $1.local.distance(to: point) })
    }
}
