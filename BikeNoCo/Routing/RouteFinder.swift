import Foundation
import CoreLocation

enum RouteFinder {
    static func route(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default
    ) -> Result<PlannedRoute, RoutingError> {
        guard !graph.edgesByID.isEmpty else {
            return .failure(.originTooFar)
        }

        let index = EdgeSpatialIndex(graph: graph)
        guard let originAnchor = index.anchor(origin, maxDistance: profile.maxSnapMeters) else {
            return .failure(.originTooFar)
        }
        guard let destinationAnchor = index.anchor(destination, maxDistance: profile.maxSnapMeters) else {
            return .failure(.destinationTooFar)
        }

        let overlay = RoutingOverlay(
            graph: graph,
            origin: originAnchor,
            destination: destinationAnchor
        )

        guard let path = astar(
            from: overlay.originNodeID,
            to: overlay.destinationNodeID,
            overlay: overlay,
            profile: profile
        ) else {
            let hint = disconnectedHint(
                origin: originAnchor,
                destination: destinationAnchor,
                graph: graph
            )
            return .failure(.noPath(hint: hint))
        }

        let coordinates = path.coordinates
        let planned = PlannedRoute.make(
            edges: path.edges,
            coordinates: coordinates,
            origin: origin,
            destination: destination
        )
        return .success(planned)
    }

    // MARK: - A*

    private struct PathResult {
        let edges: [GraphEdge]
        let coordinates: [CLLocationCoordinate2D]
    }

    private static func astar(
        from start: Int,
        to goal: Int,
        overlay: RoutingOverlay,
        profile: RoutingProfile
    ) -> PathResult? {
        if start == goal {
            let coordinate = overlay.coordinate(of: start)
            return PathResult(edges: [], coordinates: [coordinate])
        }

        let heuristicScale = profile.minimumMultiplier
        let goalPoint = overlay.localPoint(of: goal)

        var open = BinaryMinHeap<(node: Int, fScore: Double)>(
            areInIncreasingOrder: { $0.fScore < $1.fScore }
        )
        var gScore: [Int: Double] = [start: 0]
        var cameFrom: [Int: (edgeID: Int, previousNode: Int)] = [:]
        var closed: Set<Int> = []

        open.push((start, heuristicScale * overlay.localPoint(of: start).distance(to: goalPoint)))

        while let current = open.pop()?.node {
            if current == goal {
                return reconstruct(cameFrom: cameFrom, start: start, goal: goal, overlay: overlay)
            }
            if closed.contains(current) { continue }
            closed.insert(current)

            let currentG = gScore[current] ?? .infinity
            for (edge, neighbor) in overlay.neighbors(of: current) {
                if closed.contains(neighbor) { continue }
                guard let stepCost = profile.cost(for: edge) else { continue }
                let tentative = currentG + stepCost
                if tentative < (gScore[neighbor] ?? .infinity) {
                    gScore[neighbor] = tentative
                    cameFrom[neighbor] = (edge.id, current)
                    let f = tentative + heuristicScale * overlay.localPoint(of: neighbor).distance(to: goalPoint)
                    open.push((neighbor, f))
                }
            }
        }
        return nil
    }

    private static func reconstruct(
        cameFrom: [Int: (edgeID: Int, previousNode: Int)],
        start: Int,
        goal: Int,
        overlay: RoutingOverlay
    ) -> PathResult {
        var node = goal
        var edgeIDs: [Int] = []
        var nodeSequence: [Int] = [goal]
        while node != start {
            guard let step = cameFrom[node] else { break }
            edgeIDs.append(step.edgeID)
            nodeSequence.append(step.previousNode)
            node = step.previousNode
        }
        edgeIDs.reverse()
        nodeSequence.reverse()

        var edges: [GraphEdge] = []
        var coordinates: [CLLocationCoordinate2D] = []

        for (index, edgeID) in edgeIDs.enumerated() {
            guard let edge = overlay.edge(id: edgeID) else { continue }
            let fromNode = nodeSequence[index]
            let travelingForward = edge.fromID == fromNode
            edges.append(edge)

            let geom = travelingForward ? edge.geometry : edge.geometry.reversed()
            if coordinates.isEmpty {
                coordinates.append(contentsOf: geom)
            } else if geom.count > 1 {
                coordinates.append(contentsOf: geom.dropFirst())
            }
        }

        if coordinates.isEmpty {
            coordinates = [overlay.coordinate(of: start), overlay.coordinate(of: goal)]
        }
        return PathResult(edges: edges, coordinates: coordinates)
    }

    private static func disconnectedHint(
        origin: RouteAnchor,
        destination: RouteAnchor,
        graph: BikeNetworkGraph
    ) -> String? {
        let components = NodeComponents(graph: graph)
        let originComponent = components.component(of: origin.graphNodeID)
        let destinationComponent = components.component(of: destination.graphNodeID)
        if originComponent != destinationComponent {
            return "Start and destination look like they're on disconnected parts of the bike network. Street connectors are coming soon."
        }
        return nil
    }
}

/// Where a route endpoint attaches to the network.
private enum RouteAnchor {
    /// Reuse an existing graph node (preferred when the query is near a junction).
    case node(id: Int, coordinate: CLLocationCoordinate2D)
    /// Project onto the interior of an edge and insert a virtual node.
    case edge(EdgeSnap)

    /// A real graph node used for component checks (edge endpoints for virtual snaps).
    var graphNodeID: Int {
        switch self {
        case .node(let id, _): return id
        case .edge(let snap): return snap.edge.fromID
        }
    }
}

// MARK: - Snap / spatial index

private struct EdgeSnap {
    let edge: GraphEdge
    let coordinate: CLLocationCoordinate2D
    let localPoint: LocalPoint
    /// Distance along the edge geometry from `from` toward `to`.
    let distanceAlongMeters: Double
    let distanceToEdgeMeters: Double
}

private struct EdgeSpatialIndex {
    let graph: BikeNetworkGraph
    private let grid: SpatialGrid<Int>
    private let nodeGrid: SpatialGrid<Int>
    private let localGeometry: [Int: [LocalPoint]]
    /// Prefer an existing node when the query (or edge projection) is this close.
    private let nodePreferMeters: Double = 3

    init(graph: BikeNetworkGraph) {
        self.graph = graph
        var grid = SpatialGrid<Int>(cellSize: 25)
        var nodeGrid = SpatialGrid<Int>(cellSize: 25)
        var localGeometry: [Int: [LocalPoint]] = [:]
        let projection = graph.projection
        for edge in graph.edgesByID.values {
            let points = edge.geometry.map { projection.toLocal($0) }
            localGeometry[edge.id] = points
            for i in 0..<(points.count - 1) {
                grid.insertSegment(id: edge.id, from: points[i], to: points[i + 1])
            }
        }
        for node in graph.nodesByID.values {
            nodeGrid.insertPoint(id: node.id, at: projection.toLocal(node.coordinate))
        }
        self.grid = grid
        self.nodeGrid = nodeGrid
        self.localGeometry = localGeometry
    }

    func anchor(_ coordinate: CLLocationCoordinate2D, maxDistance: Double) -> RouteAnchor? {
        let query = graph.projection.toLocal(coordinate)

        if let nearestNode = nodeGrid.points(near: query, radius: min(maxDistance, nodePreferMeters))
            .min(by: { $0.distance < $1.distance }),
           let node = graph.nodesByID[nearestNode.id] {
            return .node(id: node.id, coordinate: node.coordinate)
        }

        guard let snap = snap(query: query, maxDistance: maxDistance) else { return nil }

        // If the projection lands on/near an endpoint, use that node so all incident
        // edges remain available (important when a high-stress edge is also present).
        if snap.distanceAlongMeters <= nodePreferMeters {
            return .node(id: snap.edge.fromID, coordinate: graph.nodesByID[snap.edge.fromID]?.coordinate ?? snap.coordinate)
        }
        if snap.distanceAlongMeters >= snap.edge.lengthMeters - nodePreferMeters {
            return .node(id: snap.edge.toID, coordinate: graph.nodesByID[snap.edge.toID]?.coordinate ?? snap.coordinate)
        }

        if let nearestNode = nodeGrid.points(near: snap.localPoint, radius: nodePreferMeters)
            .min(by: { $0.distance < $1.distance }),
           let node = graph.nodesByID[nearestNode.id] {
            return .node(id: node.id, coordinate: node.coordinate)
        }

        return .edge(snap)
    }

    private func snap(query: LocalPoint, maxDistance: Double) -> EdgeSnap? {
        let candidates = grid.segments(near: query, radius: maxDistance)
        var best: EdgeSnap?

        var seen: Set<Int> = []
        for candidate in candidates {
            if seen.contains(candidate.id) { continue }
            seen.insert(candidate.id)
            guard let edge = graph.edgesByID[candidate.id],
                  let points = localGeometry[edge.id],
                  let projection = project(query, onto: points) else { continue }
            if projection.distance > maxDistance { continue }
            if let current = best, projection.distance >= current.distanceToEdgeMeters {
                continue
            }
            best = EdgeSnap(
                edge: edge,
                coordinate: graph.projection.toCoordinate(projection.point),
                localPoint: projection.point,
                distanceAlongMeters: projection.distanceAlong,
                distanceToEdgeMeters: projection.distance
            )
        }
        return best
    }

    private func project(
        _ query: LocalPoint,
        onto points: [LocalPoint]
    ) -> (point: LocalPoint, distanceAlong: Double, distance: Double)? {
        guard points.count >= 2 else { return nil }
        var bestDistance = Double.infinity
        var bestPoint = points[0]
        var bestAlong = 0.0
        var traveled = 0.0

        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let segmentLength = a.distance(to: b)
            let projected = query.projected(ontoSegmentFrom: a, to: b)
            if projected.distance < bestDistance {
                bestDistance = projected.distance
                bestPoint = projected.point
                bestAlong = traveled + projected.t * segmentLength
            }
            traveled += segmentLength
        }
        return (bestPoint, bestAlong, bestDistance)
    }
}

// MARK: - Overlay graph (virtual snap nodes, no mutation of shared graph)

private struct RoutingOverlay {
    let graph: BikeNetworkGraph
    let originNodeID: Int
    let destinationNodeID: Int

    private var extraNodes: [Int: GraphNode] = [:]
    private var extraEdges: [Int: GraphEdge] = [:]
    private var extraAdjacency: [Int: [Int]] = [:]
    private var suppressedEdgeIDs: Set<Int> = []
    private var localPoints: [Int: LocalPoint] = [:]

    init(graph: BikeNetworkGraph, origin: RouteAnchor, destination: RouteAnchor) {
        self.graph = graph

        for node in graph.nodesByID.values {
            localPoints[node.id] = graph.projection.toLocal(node.coordinate)
        }

        var nextNodeID = (graph.nodesByID.keys.max() ?? 0) + 1
        let resolved = Self.resolveEndpointIDs(
            origin: origin,
            destination: destination,
            nextNodeID: &nextNodeID
        )
        self.originNodeID = resolved.originID
        self.destinationNodeID = resolved.destinationID

        var nextEdgeID = (graph.edgesByID.keys.max() ?? 0) + 1
        switch (origin, destination) {
        case (.node, .node):
            break

        case let (.node, .edge(destSnap)):
            insertSplits(
                [(nodeID: resolved.destinationID, along: destSnap.distanceAlongMeters, coordinate: destSnap.coordinate, local: destSnap.localPoint)],
                on: destSnap.edge,
                nextEdgeID: &nextEdgeID
            )

        case let (.edge(originSnap), .node):
            insertSplits(
                [(nodeID: resolved.originID, along: originSnap.distanceAlongMeters, coordinate: originSnap.coordinate, local: originSnap.localPoint)],
                on: originSnap.edge,
                nextEdgeID: &nextEdgeID
            )

        case let (.edge(originSnap), .edge(destSnap)):
            if originSnap.edge.id == destSnap.edge.id {
                var snaps = [
                    (nodeID: resolved.originID, along: originSnap.distanceAlongMeters, coordinate: originSnap.coordinate, local: originSnap.localPoint)
                ]
                if resolved.originID != resolved.destinationID {
                    snaps.append(
                        (nodeID: resolved.destinationID, along: destSnap.distanceAlongMeters, coordinate: destSnap.coordinate, local: destSnap.localPoint)
                    )
                }
                insertSplits(snaps, on: originSnap.edge, nextEdgeID: &nextEdgeID)
            } else {
                insertSplits(
                    [(nodeID: resolved.originID, along: originSnap.distanceAlongMeters, coordinate: originSnap.coordinate, local: originSnap.localPoint)],
                    on: originSnap.edge,
                    nextEdgeID: &nextEdgeID
                )
                insertSplits(
                    [(nodeID: resolved.destinationID, along: destSnap.distanceAlongMeters, coordinate: destSnap.coordinate, local: destSnap.localPoint)],
                    on: destSnap.edge,
                    nextEdgeID: &nextEdgeID
                )
            }
        }
    }

    private static func resolveEndpointIDs(
        origin: RouteAnchor,
        destination: RouteAnchor,
        nextNodeID: inout Int
    ) -> (originID: Int, destinationID: Int) {
        switch (origin, destination) {
        case let (.node(oID, _), .node(dID, _)):
            return (oID, dID)

        case let (.node(oID, _), .edge):
            let destinationID = nextNodeID
            nextNodeID += 1
            return (oID, destinationID)

        case let (.edge, .node(dID, _)):
            let originID = nextNodeID
            nextNodeID += 1
            return (originID, dID)

        case let (.edge(originSnap), .edge(destSnap)):
            if originSnap.edge.id == destSnap.edge.id,
               abs(originSnap.distanceAlongMeters - destSnap.distanceAlongMeters) < 0.5 {
                let id = nextNodeID
                nextNodeID += 1
                return (id, id)
            }
            let originID = nextNodeID
            nextNodeID += 1
            let destinationID = nextNodeID
            nextNodeID += 1
            return (originID, destinationID)
        }
    }

    func edge(id: Int) -> GraphEdge? {
        extraEdges[id] ?? graph.edgesByID[id]
    }

    func coordinate(of nodeID: Int) -> CLLocationCoordinate2D {
        if let node = extraNodes[nodeID] { return node.coordinate }
        return graph.nodesByID[nodeID]?.coordinate ?? .init(latitude: 0, longitude: 0)
    }

    func localPoint(of nodeID: Int) -> LocalPoint {
        if let point = localPoints[nodeID] { return point }
        if let node = graph.nodesByID[nodeID] {
            return graph.projection.toLocal(node.coordinate)
        }
        return LocalPoint(x: 0, y: 0)
    }

    func neighbors(of nodeID: Int) -> [(edge: GraphEdge, neighborID: Int)] {
        var results: [(GraphEdge, Int)] = []

        if let baseEdgeIDs = graph.adjacency[nodeID] {
            for edgeID in baseEdgeIDs where !suppressedEdgeIDs.contains(edgeID) {
                guard let edge = graph.edgesByID[edgeID] else { continue }
                let neighbor = edge.fromID == nodeID ? edge.toID : edge.fromID
                results.append((edge, neighbor))
            }
        }

        if let extraEdgeIDs = extraAdjacency[nodeID] {
            for edgeID in extraEdgeIDs {
                guard let edge = extraEdges[edgeID] else { continue }
                let neighbor = edge.fromID == nodeID ? edge.toID : edge.fromID
                results.append((edge, neighbor))
            }
        }

        return results
    }

    private mutating func insertSplits(
        _ snaps: [(nodeID: Int, along: Double, coordinate: CLLocationCoordinate2D, local: LocalPoint)],
        on edge: GraphEdge,
        nextEdgeID: inout Int
    ) {
        suppressedEdgeIDs.insert(edge.id)

        let unique = snaps
            .sorted { $0.along < $1.along }
            .reduce(into: [(nodeID: Int, along: Double, coordinate: CLLocationCoordinate2D, local: LocalPoint)]()) { result, snap in
                if let last = result.last, abs(last.along - snap.along) < 0.5 {
                    return
                }
                result.append(snap)
            }

        for snap in unique {
            extraNodes[snap.nodeID] = GraphNode(id: snap.nodeID, coordinate: snap.coordinate)
            localPoints[snap.nodeID] = snap.local
        }

        let localGeom = edge.geometry.map { graph.projection.toLocal($0) }
        var chain: [(nodeID: Int, along: Double, coordinate: CLLocationCoordinate2D)] = [
            (edge.fromID, 0, edge.geometry.first ?? edge.geometry[0])
        ]
        for snap in unique {
            chain.append((snap.nodeID, snap.along, snap.coordinate))
        }
        chain.append((edge.toID, edge.lengthMeters, edge.geometry.last ?? edge.geometry[0]))

        for i in 0..<(chain.count - 1) {
            let start = chain[i]
            let end = chain[i + 1]
            let length = max(0, end.along - start.along)
            if length < 0.05, start.nodeID != end.nodeID {
                // Degenerate stub at an endpoint snap — still link with tiny length so adjacency exists.
            }
            let geometry = sliceGeometry(
                localGeom: localGeom,
                fromAlong: start.along,
                toAlong: end.along,
                startCoordinate: start.coordinate,
                endCoordinate: end.coordinate
            )
            let piece = GraphEdge(
                id: nextEdgeID,
                fromID: start.nodeID,
                toID: end.nodeID,
                lengthMeters: max(length, 0.01),
                geometry: geometry,
                facilityType: edge.facilityType,
                lts: edge.lts,
                name: edge.name,
                sourceRouteID: edge.sourceRouteID,
                isConnector: edge.isConnector
            )
            extraEdges[nextEdgeID] = piece
            extraAdjacency[start.nodeID, default: []].append(nextEdgeID)
            if start.nodeID != end.nodeID {
                extraAdjacency[end.nodeID, default: []].append(nextEdgeID)
            }
            nextEdgeID += 1
        }
    }

    private func sliceGeometry(
        localGeom: [LocalPoint],
        fromAlong: Double,
        toAlong: Double,
        startCoordinate: CLLocationCoordinate2D,
        endCoordinate: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        let lo = min(fromAlong, toAlong)
        let hi = max(fromAlong, toAlong)
        var result: [CLLocationCoordinate2D] = [startCoordinate]
        var traveled = 0.0

        for i in 0..<(localGeom.count - 1) {
            let a = localGeom[i]
            let b = localGeom[i + 1]
            let segmentLength = a.distance(to: b)
            let segStart = traveled
            let segEnd = traveled + segmentLength
            traveled = segEnd

            if segEnd <= lo + 1e-9 || segStart >= hi - 1e-9 {
                continue
            }

            if segStart > lo + 1e-6, segStart < hi - 1e-6 {
                result.append(graph.projection.toCoordinate(a))
            }
        }

        if let last = result.last,
           abs(last.latitude - endCoordinate.latitude) > 1e-10
            || abs(last.longitude - endCoordinate.longitude) > 1e-10 {
            result.append(endCoordinate)
        } else if result.count == 1 {
            result.append(endCoordinate)
        }
        return result
    }
}

private extension Array where Element == (nodeID: Int, along: Double, coordinate: CLLocationCoordinate2D, local: LocalPoint) {
    func uniquedByNode() -> Self {
        var seen: Set<Int> = []
        var result: Self = []
        for item in self {
            if seen.contains(item.nodeID) { continue }
            seen.insert(item.nodeID)
            result.append(item)
        }
        return result
    }
}

// MARK: - Component membership

private struct NodeComponents {
    private let componentOf: [Int: Int]

    init(graph: BikeNetworkGraph) {
        let nodeIDs = Array(graph.nodesByID.keys)
        var indexOf: [Int: Int] = [:]
        for (i, id) in nodeIDs.enumerated() {
            indexOf[id] = i
        }
        var uf = UnionFind(count: nodeIDs.count)
        for edge in graph.edgesByID.values {
            if let a = indexOf[edge.fromID], let b = indexOf[edge.toID] {
                uf.union(a, b)
            }
        }
        var map: [Int: Int] = [:]
        for (i, id) in nodeIDs.enumerated() {
            map[id] = uf.find(i)
        }
        self.componentOf = map
    }

    func component(of nodeID: Int) -> Int {
        componentOf[nodeID] ?? nodeID
    }
}

// MARK: - Binary heap

private struct BinaryMinHeap<Element> {
    private var storage: [Element] = []
    private let areInIncreasingOrder: (Element, Element) -> Bool

    init(areInIncreasingOrder: @escaping (Element, Element) -> Bool) {
        self.areInIncreasingOrder = areInIncreasingOrder
    }

    var isEmpty: Bool { storage.isEmpty }

    mutating func push(_ element: Element) {
        storage.append(element)
        siftUp(storage.count - 1)
    }

    mutating func pop() -> Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 {
            return storage.removeLast()
        }
        let first = storage[0]
        storage[0] = storage.removeLast()
        siftDown(0)
        return first
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            if areInIncreasingOrder(storage[child], storage[parent]) {
                storage.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent
            if left < storage.count, areInIncreasingOrder(storage[left], storage[candidate]) {
                candidate = left
            }
            if right < storage.count, areInIncreasingOrder(storage[right], storage[candidate]) {
                candidate = right
            }
            if candidate == parent { break }
            storage.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
