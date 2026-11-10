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
        var timing = GraphBuildTiming()
        var state = MutableGraph(from: arcgis)

        let indexStart = CFAbsoluteTimeGetCurrent()
        let osmIndex = OSMNodeIndex(connectors: connectors, projection: arcgis.projection)
        timing.other += CFAbsoluteTimeGetCurrent() - indexStart

        let crossStart = CFAbsoluteTimeGetCurrent()
        state.ensureArcGISLocalGeometry()
        let foundCrossings = findArcGISCrossings(
            edgesByID: state.edgesByID,
            localGeometry: state.arcGISLocalGeometry
        )
        let crossingsJoined = applyCrossings(foundCrossings, state: &state, osmIndex: osmIndex)
        timing.crossingResolution = CFAbsoluteTimeGetCurrent() - crossStart
        let crossingsConsidered = foundCrossings.count

        let conflateStart = CFAbsoluteTimeGetCurrent()
        state.ensureArcGISSegmentGrid()
        guard let arcgisGrid = state.arcGISSegmentGrid else {
            return BikeNetworkGraphBuildResult(
                graph: state.freeze(),
                crossingsConsidered: crossingsConsidered,
                crossingsJoined: crossingsJoined,
                osmEdgesLoaded: connectors.count,
                osmEdgesKept: 0,
                attachmentEdgeCount: 0,
                componentsAfterPrune: 0,
                largestComponentShareAfterPrune: 0,
                timing: timing
            )
        }
        let sharedGrid = SharedSegmentGrid(arcgisGrid)
        let kept = filterNonConflated(connectors, projection: state.projection, grid: sharedGrid)
        timing.conflation = CFAbsoluteTimeGetCurrent() - conflateStart
        let osmEdgesLoaded = connectors.count
        let osmEdgesKept = kept.count

        let insertStart = CFAbsoluteTimeGetCurrent()
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
        timing.osmInsert = CFAbsoluteTimeGetCurrent() - insertStart

        let attachStart = CFAbsoluteTimeGetCurrent()
        let attachments = attachNetworks(
            state: &state,
            osmIndex: osmIndex,
            osmNodeToGraph: osmNodeToGraph,
            sharedGrid: sharedGrid
        )
        timing.attachment = CFAbsoluteTimeGetCurrent() - attachStart

        let pruneStart = CFAbsoluteTimeGetCurrent()
        let pruneStats = pruneOSMOnlyComponents(state: &state)
        timing.pruning = CFAbsoluteTimeGetCurrent() - pruneStart

        return BikeNetworkGraphBuildResult(
            graph: state.freeze(),
            crossingsConsidered: crossingsConsidered,
            crossingsJoined: crossingsJoined,
            osmEdgesLoaded: osmEdgesLoaded,
            osmEdgesKept: osmEdgesKept,
            attachmentEdgeCount: attachments,
            componentsAfterPrune: pruneStats.componentCount,
            largestComponentShareAfterPrune: pruneStats.largestShare,
            timing: timing
        )
    }

    /// Drop every connected component that contains no ArcGIS (non-connector) edge.
    @discardableResult
    private static func pruneOSMOnlyComponents(state: inout MutableGraph) -> (componentCount: Int, largestShare: Double) {
        let nodeIDs = Array(state.nodesByID.keys)
        guard !nodeIDs.isEmpty else { return (0, 0) }

        var indexOf: [Int: Int] = [:]
        for (i, id) in nodeIDs.enumerated() {
            indexOf[id] = i
        }
        var uf = UnionFind(count: nodeIDs.count)
        for edge in state.edgesByID.values {
            if let a = indexOf[edge.fromID], let b = indexOf[edge.toID] {
                uf.union(a, b)
            }
        }

        var rootHasArcGIS: [Int: Bool] = [:]
        var lengthByRoot: [Int: Double] = [:]
        for edge in state.edgesByID.values {
            guard let root = indexOf[edge.fromID].map({ uf.find($0) }) else { continue }
            lengthByRoot[root, default: 0] += edge.lengthMeters
            if !edge.isConnector {
                rootHasArcGIS[root] = true
            }
        }

        var keepRoots: Set<Int> = []
        for (root, hasArcGIS) in rootHasArcGIS where hasArcGIS {
            keepRoots.insert(root)
        }

        let dropNodeIDs: Set<Int> = Set(nodeIDs.enumerated().compactMap { index, id in
            keepRoots.contains(uf.find(index)) ? nil : id
        })

        if !dropNodeIDs.isEmpty {
            let dropEdgeIDs = state.edgesByID.values.compactMap { edge -> Int? in
                if dropNodeIDs.contains(edge.fromID) || dropNodeIDs.contains(edge.toID) {
                    return edge.id
                }
                return nil
            }
            for edgeID in dropEdgeIDs {
                state.removeEdge(id: edgeID)
            }
            for nodeID in dropNodeIDs {
                state.nodesByID.removeValue(forKey: nodeID)
                state.nodeLocal.removeValue(forKey: nodeID)
                state.adjacency.removeValue(forKey: nodeID)
            }
        }

        let keptLength = lengthByRoot.filter { keepRoots.contains($0.key) }.values.reduce(0, +)
        let largest = lengthByRoot.filter { keepRoots.contains($0.key) }.values.max() ?? 0
        return (keepRoots.count, keptLength > 0 ? largest / keptLength : 0)
    }

    // MARK: - Crossing resolution

    /// Join previously detected ArcGIS X-crossings that have a nearby at-grade OSM junction.
    private static func applyCrossings(
        _ crossings: [Crossing],
        state: inout MutableGraph,
        osmIndex: OSMNodeIndex
    ) -> Int {
        var joined = 0
        var removedEdgeIDs: Set<Int> = []

        for crossing in crossings {
            if removedEdgeIDs.contains(crossing.edgeAID) || removedEdgeIDs.contains(crossing.edgeBID) {
                continue
            }
            guard osmIndex.bestAtGradeJunction(near: crossing.point, radius: crossingJoinMeters) != nil else {
                continue
            }
            guard let edgeA = state.edgesByID[crossing.edgeAID],
                  let edgeB = state.edgesByID[crossing.edgeBID] else { continue }

            let sharedNodeID = state.addNode(at: crossing.point)
            if splitEdge(edgeA, at: crossing.point, sharedNodeID: sharedNodeID, state: &state) {
                removedEdgeIDs.insert(edgeA.id)
            }
            if splitEdge(edgeB, at: crossing.point, sharedNodeID: sharedNodeID, state: &state) {
                removedEdgeIDs.insert(edgeB.id)
            }
            joined += 1
        }

        return joined
    }

    private struct Crossing {
        let edgeAID: Int
        let edgeBID: Int
        let point: LocalPoint
    }

    /// Pair segments that share a grid cell and test only those two segments for a proper hit.
    /// Crossing geometry occupies at least one shared cell, so no halo walk is required.
    private static func findArcGISCrossings(
        edgesByID: [Int: GraphEdge],
        localGeometry: [Int: [LocalPoint]]
    ) -> [Crossing] {
        var grid = SpatialGrid<EdgeSeg>(cellSize: 25)
        for (edgeID, points) in localGeometry {
            for i in 0..<(points.count - 1) {
                grid.insertSegment(id: EdgeSeg(edgeID: edgeID, segmentIndex: i), from: points[i], to: points[i + 1])
            }
        }

        var results: [Crossing] = []
        var seen: Set<EdgePairKey> = []
        grid.forEachSegmentCell { records in
            guard records.count >= 2 else { return }
            for i in 0..<(records.count - 1) {
                let a = records[i]
                for j in (i + 1)..<records.count {
                    let b = records[j]
                    if a.id.edgeID == b.id.edgeID { continue }
                    let key = EdgePairKey(a: a.id.edgeID, b: b.id.edgeID)
                    if seen.contains(key) { continue }
                    guard let edgeA = edgesByID[a.id.edgeID],
                          let edgeB = edgesByID[b.id.edgeID] else { continue }
                    if sharesNode(edgeA, edgeB) {
                        seen.insert(key)
                        continue
                    }
                    guard let hit = LocalProjection.properIntersection(
                        a1: a.a, a2: a.b,
                        b1: b.a, b2: b.b
                    ) else { continue }
                    seen.insert(key)
                    results.append(Crossing(edgeAID: edgeA.id, edgeBID: edgeB.id, point: hit))
                }
            }
        }
        return results
    }

    private struct EdgeSeg: Hashable {
        let edgeID: Int
        let segmentIndex: Int
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

    private static func filterNonConflated(
        _ connectors: [OSMConnectorEdge],
        projection: LocalProjection,
        grid: SharedSegmentGrid
    ) -> [OSMConnectorEdge] {
        let count = connectors.count
        var dropFlags = [Bool](repeating: false, count: count)
        dropFlags.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: count) { i in
                buffer[i] = shouldConflate(connectors[i], projection: projection, grid: grid)
            }
        }
        var kept: [OSMConnectorEdge] = []
        kept.reserveCapacity(count / 2)
        for i in 0..<count where !dropFlags[i] {
            kept.append(connectors[i])
        }
        return kept
    }

    /// Sample OSM geometry about every 5 m while walking the polyline once.
    private static func shouldConflate(
        _ edge: OSMConnectorEdge,
        projection: LocalProjection,
        grid: SharedSegmentGrid
    ) -> Bool {
        let local = edge.coordinates.map { projection.toLocal($0) }
        guard local.count >= 2 else { return true }
        let total = polylineLength(local)
        guard total > 0.5 else { return false }

        var covered = 0.0
        let step = 5.0
        var traveled = 0.0
        var nextSample = 0.0

        for i in 0..<(local.count - 1) {
            let a = local[i]
            let b = local[i + 1]
            let segLen = a.distance(to: b)
            guard segLen > 1e-9 else { continue }

            while nextSample <= traveled + segLen + 1e-9 {
                let remainingTotal = total - nextSample
                if covered / total >= conflationLengthFraction { return true }
                if (covered + remainingTotal) / total < conflationLengthFraction { return false }

                let t = (nextSample - traveled) / segLen
                let point = LocalPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                if grid.hasSegment(near: point, radius: conflationDistanceMeters) {
                    covered += min(step, remainingTotal)
                }
                nextSample += step
            }
            traveled += segLen
        }
        return (covered / total) >= conflationLengthFraction
    }

    // MARK: - Attachments

    private static func attachNetworks(
        state: inout MutableGraph,
        osmIndex: OSMNodeIndex,
        osmNodeToGraph: [Int64: Int],
        sharedGrid: SharedSegmentGrid
    ) -> Int {
        var count = 0
        var attachedOSMNodes: Set<Int> = []

        // ArcGIS node → nearest eligible OSM node within 15 m
        for node in state.nodesByID.values {
            let incident = state.adjacency[node.id] ?? []
            let hasArcGIS = incident.contains { id in
                state.edgesByID[id]?.isConnector == false
            }
            guard hasArcGIS else { continue }

            let local = state.nodeLocal[node.id] ?? state.projection.toLocal(node.coordinate)
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
            attachedOSMNodes.insert(osmGraphID)
            count += 1
        }

        // OSM node → ArcGIS edge interior T-attachment within 8 m.
        // Collect candidates concurrently, group by edge, then split each edge once.
        state.ensureArcGISLocalGeometry()
        let osmEntries = Array(osmNodeToGraph)
        var candidateSlots: [(osmGraphID: Int, edgeID: Int, point: LocalPoint, distance: Double)?] = Array(
            repeating: nil,
            count: osmEntries.count
        )
        let edgesByID = state.edgesByID
        let localGeometry = state.arcGISLocalGeometry
        let edgeLengths = state.arcGISEdgeLength
        let skipOSM = attachedOSMNodes
        candidateSlots.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: osmEntries.count) { index in
                let (osmID, graphID) = osmEntries[index]
                if skipOSM.contains(graphID) { return }
                guard let info = osmIndex.nodes[osmID], info.isAttachable else { return }
                let hits = sharedGrid.segments(near: info.local, radius: tAttachMeters)
                var best: (edgeID: Int, point: LocalPoint, distance: Double)?
                for hit in hits {
                    guard let edge = edgesByID[hit.id], !edge.isConnector else { continue }
                    let projected = info.local.projected(ontoSegmentFrom: hit.a, to: hit.b)
                    guard projected.distance <= tAttachMeters else { continue }
                    guard let edgeLocal = localGeometry[edge.id],
                          let along = projectOntoPolyline(projected.point, points: edgeLocal) else { continue }
                    let edgeLen = edgeLengths[edge.id] ?? polylineLength(edgeLocal)
                    if along.distanceAlong <= 1.0 || along.distanceAlong >= (edgeLen - 1.0) {
                        continue
                    }
                    if let current = best, projected.distance >= current.distance { continue }
                    best = (edge.id, projected.point, projected.distance)
                }
                if let hit = best {
                    buffer[index] = (graphID, hit.edgeID, hit.point, hit.distance)
                }
            }
        }
        let candidates = candidateSlots.compactMap { $0 }

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
    var arcGISLocalGeometry: [Int: [LocalPoint]] = [:]
    var arcGISEdgeLength: [Int: Double] = [:]

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
        // Connector inserts do not affect the ArcGIS-only spatial index.
        if !isConnector {
            invalidateArcGISIndexes()
        }
    }

    mutating func removeEdge(id: Int) {
        guard let edge = edgesByID.removeValue(forKey: id) else { return }
        adjacency[edge.fromID] = (adjacency[edge.fromID] ?? []).filter { $0 != id }
        if edge.fromID != edge.toID {
            adjacency[edge.toID] = (adjacency[edge.toID] ?? []).filter { $0 != id }
        }
        if !edge.isConnector {
            invalidateArcGISIndexes()
        }
    }

    mutating func invalidateArcGISIndexes() {
        arcGISSegmentGrid = nil
        arcGISLocalGeometry = [:]
        arcGISEdgeLength = [:]
    }

    mutating func ensureArcGISSegmentGrid() {
        if arcGISSegmentGrid != nil { return }
        ensureArcGISLocalGeometry()
        var grid = SpatialGrid<Int>(cellSize: 25)
        for (edgeID, points) in arcGISLocalGeometry {
            for i in 0..<(points.count - 1) {
                grid.insertSegment(id: edgeID, from: points[i], to: points[i + 1])
            }
        }
        arcGISSegmentGrid = grid
    }

    mutating func ensureArcGISLocalGeometry() {
        if !arcGISLocalGeometry.isEmpty { return }
        var geometry: [Int: [LocalPoint]] = [:]
        var lengths: [Int: Double] = [:]
        geometry.reserveCapacity(edgesByID.count)
        for edge in edgesByID.values where !edge.isConnector {
            let points = edge.geometry.map { projection.toLocal($0) }
            geometry[edge.id] = points
            var length = 0.0
            for i in 1..<points.count {
                length += points[i - 1].distance(to: points[i])
            }
            lengths[edge.id] = length
        }
        arcGISLocalGeometry = geometry
        arcGISEdgeLength = lengths
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

private let osmConnectorSourceID = UUID(
    uuid: (0xA1, 0x11, 0x11, 0x11, 0xB2, 0x22, 0xC3, 0x33, 0xD4, 0x44, 0xE5, 0x55, 0x55, 0x55, 0x55, 0x55)
)

// MARK: - Shared segment grid (concurrent conflation / attachment)

/// Holds an immutable `SpatialGrid` so concurrent workers can share one copy safely.
private final class SharedSegmentGrid: @unchecked Sendable {
    private let grid: SpatialGrid<Int>

    init(_ grid: SpatialGrid<Int>) {
        self.grid = grid
    }

    func hasSegment(near query: LocalPoint, radius: Double) -> Bool {
        grid.hasSegment(near: query, radius: radius)
    }

    func segments(near query: LocalPoint, radius: Double) -> [(id: Int, a: LocalPoint, b: LocalPoint, distance: Double)] {
        grid.segments(near: query, radius: radius)
    }
}

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
    let atGradeJunctions: [NodeInfo]
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
                if let existing = bridgeTunnelOnly[nid] {
                    // Node is grade-separated only if every incident edge is bridge/tunnel.
                    bridgeTunnelOnly[nid] = existing && gradeSeparated
                } else {
                    bridgeTunnelOnly[nid] = gradeSeparated
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
        self.atGradeJunctions = []
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
