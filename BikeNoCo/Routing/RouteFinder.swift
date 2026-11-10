import Foundation
import CoreLocation

/// Reusable snap index for many routes against the same graph (distance-loop search).
/// Thread-safe for concurrent bearing searches.
final class RoutingIndex: @unchecked Sendable {
    let graph: BikeNetworkGraph
    private let index: EdgeSpatialIndex
    private let lock = NSLock()

    init(graph: BikeNetworkGraph) {
        self.graph = graph
        self.index = EdgeSpatialIndex(graph: graph)
    }

    fileprivate func anchor(
        _ coordinate: CLLocationCoordinate2D,
        maxDistance: Double
    ) -> RouteAnchor? {
        lock.lock()
        defer { lock.unlock() }
        return index.anchor(coordinate, maxDistance: maxDistance)
    }
}

enum RouteFinder {
    /// Exact outbound-edge reuse multiplier for return-leg search.
    static let outboundReuseMultiplier: Double = 5
    /// Multiplier for edges whose midpoint is within `nearOutboundMeters` of outbound geometry.
    static let nearOutboundMultiplier: Double = 2
    /// Distance threshold for the near-outbound penalty / overlap accounting.
    static let nearOutboundMeters: Double = 40
    /// Midpoints this close to outbound geometry count as reuse (covers overlay splits).
    fileprivate static let coincidentOutboundMeters: Double = 1.0

    static func route(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default,
        edgeCostMultipliers: [Int: Double] = [:]
    ) -> Result<PlannedRoute, RoutingError> {
        route(
            from: origin,
            to: destination,
            graph: graph,
            profile: profile,
            edgeCostMultipliers: edgeCostMultipliers,
            reusePenalty: nil,
            routingIndex: nil
        )
    }

    /// Outbound origin→via, then return via→origin with reuse penalties. Joins into a loop trip.
    static func loop(
        from origin: CLLocationCoordinate2D,
        via destination: CLLocationCoordinate2D,
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default
    ) -> Result<PlannedRoute, RoutingError> {
        let outboundResult = route(
            from: origin,
            to: destination,
            graph: graph,
            profile: profile
        )
        switch outboundResult {
        case .failure(let error):
            return .failure(error)
        case .success(let outbound):
            return loop(outbound: outbound, graph: graph, profile: profile)
        }
    }

    /// Build a loop from an already-computed outbound one-way route.
    static func loop(
        outbound: PlannedRoute,
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default
    ) -> Result<PlannedRoute, RoutingError> {
        let reuse = ReusePenaltyContext(
            outboundEdges: outbound.edges,
            outboundCoordinates: outbound.coordinates,
            graph: graph
        )
        let returnResult = route(
            from: outbound.destination,
            to: outbound.origin,
            graph: graph,
            profile: profile,
            edgeCostMultipliers: reuse.edgeMultipliers,
            reusePenalty: reuse,
            routingIndex: nil
        )
        switch returnResult {
        case .failure(let error):
            return .failure(error)
        case .success(let returnLeg):
            let overlap = reuse.overlapShare(of: returnLeg.edges)
            return .success(
                PlannedRoute.loop(
                    outbound: outbound,
                    returnLeg: returnLeg,
                    overlapShare: overlap
                )
            )
        }
    }

    /// Route through an ordered waypoint list (first = start, last = end).
    /// When `cumulativeReusePenalties` is true, each leg after the first applies 06a
    /// reuse penalties against all earlier legs (used by the distance-loop planner).
    static func routeThrough(
        waypoints: [CLLocationCoordinate2D],
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default,
        cumulativeReusePenalties: Bool = false,
        tripShape: TripShape = .oneWay,
        routingIndex: RoutingIndex? = nil
    ) -> Result<PlannedRoute, RoutingError> {
        guard waypoints.count >= 2 else {
            return .failure(.noPath(hint: "Need at least two waypoints to route."))
        }

        let index = routingIndex ?? RoutingIndex(graph: graph)
        var segments: [PlannedRoute] = []
        var priorEdges: [GraphEdge] = []
        var priorCoordinates: [CLLocationCoordinate2D] = []
        var laterOverlapped = 0.0
        var laterTotal = 0.0

        for indexInPath in 0..<(waypoints.count - 1) {
            let from = waypoints[indexInPath]
            let to = waypoints[indexInPath + 1]
            let reuse: ReusePenaltyContext?
            let multipliers: [Int: Double]
            if cumulativeReusePenalties, !priorEdges.isEmpty {
                let context = ReusePenaltyContext(
                    outboundEdges: priorEdges,
                    outboundCoordinates: priorCoordinates,
                    graph: graph
                )
                reuse = context
                multipliers = context.edgeMultipliers
            } else {
                reuse = nil
                multipliers = [:]
            }

            let result = route(
                from: from,
                to: to,
                graph: graph,
                profile: profile,
                edgeCostMultipliers: multipliers,
                reusePenalty: reuse,
                routingIndex: index
            )
            switch result {
            case .failure(let error):
                return .failure(error)
            case .success(let segment):
                if let reuse {
                    laterOverlapped += reuse.overlapShare(of: segment.edges) * segment.totalDistanceMeters
                    laterTotal += segment.totalDistanceMeters
                }
                segments.append(segment)
                priorEdges.append(contentsOf: segment.edges)
                if priorCoordinates.isEmpty {
                    priorCoordinates = segment.coordinates
                } else if let first = segment.coordinates.first,
                          let last = priorCoordinates.last,
                          abs(first.latitude - last.latitude) < 1e-8,
                          abs(first.longitude - last.longitude) < 1e-8 {
                    priorCoordinates.append(contentsOf: segment.coordinates.dropFirst())
                } else {
                    priorCoordinates.append(contentsOf: segment.coordinates)
                }
            }
        }

        let overlapShare: Double? = cumulativeReusePenalties && laterTotal > 0
            ? min(1, laterOverlapped / laterTotal)
            : nil
        let origin = waypoints[0]
        let destination = waypoints[waypoints.count - 1]
        return .success(
            PlannedRoute.joining(
                segments: segments,
                origin: origin,
                destination: destination,
                tripShape: tripShape,
                overlapShare: overlapShare
            )
        )
    }

    private static func route(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        graph: BikeNetworkGraph,
        profile: RoutingProfile,
        edgeCostMultipliers: [Int: Double],
        reusePenalty: ReusePenaltyContext?,
        routingIndex: RoutingIndex?
    ) -> Result<PlannedRoute, RoutingError> {
        guard !graph.edgesByID.isEmpty else {
            return .failure(.originTooFar)
        }

        let originAnchor: RouteAnchor?
        let destinationAnchor: RouteAnchor?
        if let routingIndex {
            originAnchor = routingIndex.anchor(origin, maxDistance: profile.maxSnapMeters)
            destinationAnchor = routingIndex.anchor(destination, maxDistance: profile.maxSnapMeters)
        } else {
            let index = EdgeSpatialIndex(graph: graph)
            originAnchor = index.anchor(origin, maxDistance: profile.maxSnapMeters)
            destinationAnchor = index.anchor(destination, maxDistance: profile.maxSnapMeters)
        }
        guard let originAnchor else {
            return .failure(.originTooFar)
        }
        guard let destinationAnchor else {
            return .failure(.destinationTooFar)
        }

        let overlay = RoutingOverlay(
            graph: graph,
            origin: originAnchor,
            destination: destinationAnchor
        )

        let multiplier: (GraphEdge) -> Double = { edge in
            if let mapped = edgeCostMultipliers[edge.id] {
                return mapped
            }
            if let reusePenalty {
                return reusePenalty.multiplier(forUnmappedEdge: edge)
            }
            return 1
        }

        guard let path = astar(
            from: overlay.originNodeID,
            to: overlay.destinationNodeID,
            overlay: overlay,
            profile: profile,
            costMultiplier: multiplier
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
        profile: RoutingProfile,
        costMultiplier: (GraphEdge) -> Double = { _ in 1 }
    ) -> PathResult? {
        if start == goal {
            let coordinate = overlay.coordinate(of: start)
            return PathResult(edges: [], coordinates: [coordinate])
        }

        // Penalties only raise costs, so the unpenalized minimum multiplier stays admissible.
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
                guard let baseCost = profile.cost(for: edge) else { continue }
                let stepCost = baseCost * costMultiplier(edge)
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

// MARK: - Return-leg reuse penalties

/// Penalizes outbound edges (×5) and edges near outbound geometry (×2) during return search.
private struct ReusePenaltyContext {
    let outboundEdgeIDs: Set<Int>
    let edgeMultipliers: [Int: Double]
    private let projection: LocalProjection
    private let outboundLocals: [LocalPoint]
    private let grid: SpatialGrid<Int>

    init(
        outboundEdges: [GraphEdge],
        outboundCoordinates: [CLLocationCoordinate2D],
        graph: BikeNetworkGraph
    ) {
        let projection = graph.projection
        self.projection = projection
        self.outboundEdgeIDs = Set(outboundEdges.map(\.id))
        // Downsample long polylines so the near-outbound grid stays cheap to build/query.
        let outboundLocals = Self.downsample(
            outboundCoordinates.map { projection.toLocal($0) },
            everyMeters: 20
        )
        self.outboundLocals = outboundLocals

        var grid = SpatialGrid<Int>(cellSize: 25)
        if outboundLocals.count >= 2 {
            for i in 0..<(outboundLocals.count - 1) {
                grid.insertSegment(id: i, from: outboundLocals[i], to: outboundLocals[i + 1])
            }
        }
        self.grid = grid

        var multipliers: [Int: Double] = [:]
        for edge in outboundEdges {
            multipliers[edge.id] = RouteFinder.outboundReuseMultiplier
        }
        // Near-outbound ×2 is resolved on demand in `multiplier(forUnmappedEdge:)` via the
        // outbound geometry grid — scanning every graph edge here is too slow for loop search.
        self.edgeMultipliers = multipliers
    }

    private static func downsample(_ points: [LocalPoint], everyMeters: Double) -> [LocalPoint] {
        guard points.count >= 2 else { return points }
        var result: [LocalPoint] = [points[0]]
        var sinceLast = 0.0
        for i in 1..<points.count {
            let step = points[i - 1].distance(to: points[i])
            sinceLast += step
            if sinceLast >= everyMeters || i == points.count - 1 {
                result.append(points[i])
                sinceLast = 0
            }
        }
        return result
    }

    private static func geometricMidpoint(
        of edge: GraphEdge,
        projection: LocalProjection
    ) -> LocalPoint? {
        guard !edge.geometry.isEmpty else { return nil }
        if edge.geometry.count == 1 {
            return projection.toLocal(edge.geometry[0])
        }
        let locals = edge.geometry.map { projection.toLocal($0) }
        var total = 0.0
        for i in 1..<locals.count {
            total += locals[i - 1].distance(to: locals[i])
        }
        if total < 1e-6 {
            return locals[locals.count / 2]
        }
        let target = total / 2
        var traveled = 0.0
        for i in 1..<locals.count {
            let segment = locals[i - 1].distance(to: locals[i])
            if traveled + segment >= target - 1e-9 {
                let t = segment > 0 ? (target - traveled) / segment : 0
                return LocalPoint(
                    x: locals[i - 1].x + t * (locals[i].x - locals[i - 1].x),
                    y: locals[i - 1].y + t * (locals[i].y - locals[i - 1].y)
                )
            }
            traveled += segment
        }
        return locals.last
    }

    private static func distance(
        from point: LocalPoint,
        toOutbound outboundLocals: [LocalPoint],
        grid: SpatialGrid<Int>
    ) -> Double {
        guard outboundLocals.count >= 2 else {
            if let only = outboundLocals.first {
                return point.distance(to: only)
            }
            return .infinity
        }
        let candidates = grid.segments(near: point, radius: RouteFinder.nearOutboundMeters)
        var best = Double.infinity
        let pairs: [(LocalPoint, LocalPoint)]
        if candidates.isEmpty {
            pairs = (0..<(outboundLocals.count - 1)).map { (outboundLocals[$0], outboundLocals[$0 + 1]) }
        } else {
            pairs = candidates.map { ($0.a, $0.b) }
        }
        for (a, b) in pairs {
            best = min(best, point.projected(ontoSegmentFrom: a, to: b).distance)
        }
        return best
    }

    /// For overlay / unmapped edges: coincident with outbound → ×5, within 40 m → ×2.
    func multiplier(forUnmappedEdge edge: GraphEdge) -> Double {
        let distance = distanceToOutbound(midpoint(of: edge))
        if distance <= RouteFinder.coincidentOutboundMeters {
            return RouteFinder.outboundReuseMultiplier
        }
        if distance <= RouteFinder.nearOutboundMeters {
            return RouteFinder.nearOutboundMultiplier
        }
        return 1
    }

    /// Also apply near-outbound ×2 for all graph edges when building a full map is useful in tests.
    func multiplier(for edge: GraphEdge) -> Double {
        if let mapped = edgeMultipliers[edge.id] {
            return mapped
        }
        return multiplier(forUnmappedEdge: edge)
    }

    /// Fraction of return-leg length on outbound edges or within 40 m of outbound geometry.
    func overlapShare(of returnEdges: [GraphEdge]) -> Double {
        let total = returnEdges.reduce(0.0) { $0 + $1.lengthMeters }
        guard total > 0 else { return 0 }
        var overlapped = 0.0
        for edge in returnEdges {
            if outboundEdgeIDs.contains(edge.id) {
                overlapped += edge.lengthMeters
                continue
            }
            if distanceToOutbound(midpoint(of: edge)) <= RouteFinder.nearOutboundMeters {
                overlapped += edge.lengthMeters
            }
        }
        return min(1, overlapped / total)
    }

    private func midpoint(of edge: GraphEdge) -> LocalPoint {
        Self.geometricMidpoint(of: edge, projection: projection) ?? LocalPoint(x: 0, y: 0)
    }

    private func distanceToOutbound(_ point: LocalPoint) -> Double {
        Self.distance(from: point, toOutbound: outboundLocals, grid: grid)
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
