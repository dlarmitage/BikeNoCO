import Foundation
import CoreLocation

struct BikeNetworkGraphBuilder {
    struct Config {
        /// Cluster path endpoints that fall within this distance.
        var endpointSnapMeters: Double = 12
        /// Split/join when an endpoint falls within this distance of another polyline's interior.
        /// Kept tighter than endpoint snap so parallel geometry (street + trail, both curb sides)
        /// about 8–10 m apart is not stitched along its length.
        var tJunctionSnapMeters: Double = 8
        var gapSearchMeters: Double = 25
        var gridCellMeters: Double = 25
        /// Fort Collins / Loveland, matching spec ~40.5 N.
        var originLatitude: Double = 40.5
        var originLongitude: Double = -105.08
    }

    static func build(from routes: [BikeRoute], config: Config = Config()) -> BikeNetworkGraph {
        Engine(config: config).build(from: routes)
    }
}

private struct Engine {
    let config: BikeNetworkGraphBuilder.Config
    let projection: LocalProjection

    init(config: BikeNetworkGraphBuilder.Config) {
        self.config = config
        self.projection = LocalProjection(
            originLatitude: config.originLatitude,
            originLongitude: config.originLongitude
        )
    }

    private struct PolylineInput {
        let route: BikeRoute
        let points: [LocalPoint]
        var startSite: Int = 0
        var endSite: Int = 0
    }

    private struct Site {
        enum Kind { case endpoint, split }
        var point: LocalPoint
        var kind: Kind
    }

    private struct Split {
        let polylineIndex: Int
        let segmentIndex: Int
        let t: Double
        let point: LocalPoint
        let siteIndex: Int
    }

    private struct PolySegmentID: Hashable {
        let polylineIndex: Int
        let segmentIndex: Int
    }

    func build(from routes: [BikeRoute]) -> BikeNetworkGraph {
        var polylines = collectPolylines(from: routes)
        if polylines.isEmpty {
            return BikeNetworkGraph(
                nodesByID: [:],
                edgesByID: [:],
                adjacency: [:],
                projection: projection
            )
        }

        var sites: [Site] = []
        for i in polylines.indices {
            let startSite = sites.count
            sites.append(Site(point: polylines[i].points[0], kind: .endpoint))
            let endSite = sites.count
            sites.append(Site(point: polylines[i].points[polylines[i].points.count - 1], kind: .endpoint))
            polylines[i].startSite = startSite
            polylines[i].endSite = endSite
        }

        var uf = UnionFind(count: sites.count)
        clusterCloseSites(sites: sites, uf: &uf)

        var segmentGrid = SpatialGrid<PolySegmentID>(cellSize: config.gridCellMeters)
        for (polylineIndex, polyline) in polylines.enumerated() {
            let points = polyline.points
            for s in 0..<(points.count - 1) {
                segmentGrid.insertSegment(
                    id: PolySegmentID(polylineIndex: polylineIndex, segmentIndex: s),
                    from: points[s],
                    to: points[s + 1]
                )
            }
        }

        var splits: [Split] = []
        for (polylineIndex, polyline) in polylines.enumerated() {
            considerTJunction(
                fromSite: polyline.startSite,
                polylineIndex: polylineIndex,
                polylines: polylines,
                segmentGrid: segmentGrid,
                sites: &sites,
                uf: &uf,
                splits: &splits
            )
            considerTJunction(
                fromSite: polyline.endSite,
                polylineIndex: polylineIndex,
                polylines: polylines,
                segmentGrid: segmentGrid,
                sites: &sites,
                uf: &uf,
                splits: &splits
            )
        }

        clusterCloseSites(sites: sites, uf: &uf)

        let (nodesByID, nodeIDByRoot, nodeLocal) = makeNodes(sites: sites, uf: &uf)
        let (edgesByID, adjacency) = makeEdges(
            polylines: polylines,
            splits: splits,
            sites: sites,
            uf: &uf,
            nodeIDByRoot: nodeIDByRoot,
            nodeLocal: nodeLocal
        )

        return BikeNetworkGraph(
            nodesByID: nodesByID,
            edgesByID: edgesByID,
            adjacency: adjacency,
            projection: projection
        )
    }

    private func collectPolylines(from routes: [BikeRoute]) -> [PolylineInput] {
        var result: [PolylineInput] = []
        for route in routes where route.facilityType != .recommendedRide {
            for path in route.paths {
                let points = collapse(path)
                guard points.count >= 2 else { continue }
                result.append(PolylineInput(route: route, points: points))
            }
        }
        return result
    }

    private func collapse(_ path: [CLLocationCoordinate2D]) -> [LocalPoint] {
        var points: [LocalPoint] = []
        for coordinate in path {
            let point = projection.toLocal(coordinate)
            if let last = points.last, last.distance(to: point) < 0.01 { continue }
            points.append(point)
        }
        return points
    }

    private func clusterCloseSites(sites: [Site], uf: inout UnionFind) {
        var grid = SpatialGrid<Int>(cellSize: config.gridCellMeters)
        for (index, site) in sites.enumerated() {
            grid.insertPoint(id: index, at: site.point)
        }
        let snap = config.endpointSnapMeters
        for (index, site) in sites.enumerated() {
            for hit in grid.points(near: site.point, radius: snap) where hit.id > index {
                if hit.distance <= snap {
                    uf.union(index, hit.id)
                }
            }
        }
    }

    private func considerTJunction(
        fromSite: Int,
        polylineIndex: Int,
        polylines: [PolylineInput],
        segmentGrid: SpatialGrid<PolySegmentID>,
        sites: inout [Site],
        uf: inout UnionFind,
        splits: inout [Split]
    ) {
        let endpoint = sites[fromSite].point
        let tSnap = config.tJunctionSnapMeters
        let endSnap = config.endpointSnapMeters
        let nearby = segmentGrid.segments(near: endpoint, radius: tSnap)

        var bestByPolyline: [Int: (segmentIndex: Int, t: Double, point: LocalPoint, distance: Double)] = [:]
        for hit in nearby {
            if hit.id.polylineIndex == polylineIndex { continue }
            let projectionOnSegment = endpoint.projected(ontoSegmentFrom: hit.a, to: hit.b)
            if let current = bestByPolyline[hit.id.polylineIndex], current.distance <= projectionOnSegment.distance {
                continue
            }
            bestByPolyline[hit.id.polylineIndex] = (
                hit.id.segmentIndex,
                projectionOnSegment.t,
                projectionOnSegment.point,
                projectionOnSegment.distance
            )
        }

        var best: (polylineIndex: Int, segmentIndex: Int, t: Double, point: LocalPoint, distance: Double)?
        for (otherIndex, candidate) in bestByPolyline {
            guard candidate.distance <= tSnap else { continue }
            let otherPoints = polylines[otherIndex].points
            guard let first = otherPoints.first, let last = otherPoints.last else { continue }
            // Endpoint-to-endpoint is handled by clustering. Only skip T-joins when this
            // endpoint itself is already within endpoint snap of Q's start/end.
            if endpoint.distance(to: first) <= endSnap || endpoint.distance(to: last) <= endSnap { continue }
            if let current = best, candidate.distance >= current.distance { continue }
            best = (otherIndex, candidate.segmentIndex, candidate.t, candidate.point, candidate.distance)
        }

        guard let hit = best else { return }

        let siteIndex = uf.add()
        sites.append(Site(point: hit.point, kind: .split))
        uf.union(fromSite, siteIndex)
        splits.append(
            Split(
                polylineIndex: hit.polylineIndex,
                segmentIndex: hit.segmentIndex,
                t: hit.t,
                point: hit.point,
                siteIndex: siteIndex
            )
        )
    }

    private func makeNodes(
        sites: [Site],
        uf: inout UnionFind
    ) -> (nodesByID: [Int: GraphNode], nodeIDByRoot: [Int: Int], nodeLocal: [Int: LocalPoint]) {
        var grouped: [Int: [Int]] = [:]
        for index in sites.indices {
            grouped[uf.find(index), default: []].append(index)
        }

        var nodesByID: [Int: GraphNode] = [:]
        var nodeIDByRoot: [Int: Int] = [:]
        var nodeLocal: [Int: LocalPoint] = [:]
        var nextID = 0

        for (root, members) in grouped.sorted(by: { $0.key < $1.key }) {
            let splitPoints = members.compactMap { sites[$0].kind == .split ? sites[$0].point : nil }
            let source = splitPoints.isEmpty ? members.map { sites[$0].point } : splitPoints
            let local = average(source)
            let node = GraphNode(id: nextID, coordinate: projection.toCoordinate(local))
            nodesByID[nextID] = node
            nodeIDByRoot[root] = nextID
            nodeLocal[nextID] = local
            nextID += 1
        }

        return (nodesByID, nodeIDByRoot, nodeLocal)
    }

    private func makeEdges(
        polylines: [PolylineInput],
        splits: [Split],
        sites: [Site],
        uf: inout UnionFind,
        nodeIDByRoot: [Int: Int],
        nodeLocal: [Int: LocalPoint]
    ) -> (edgesByID: [Int: GraphEdge], adjacency: [Int: [Int]]) {
        let splitsByPolyline = Dictionary(grouping: splits, by: \.polylineIndex)
        var edgesByID: [Int: GraphEdge] = [:]
        var adjacency: [Int: [Int]] = [:]
        var nextEdgeID = 0

        func nodeID(forSite site: Int) -> Int? {
            nodeIDByRoot[uf.find(site)]
        }

        for (polylineIndex, polyline) in polylines.enumerated() {
            let rebuilt = rebuildVertices(
                points: polyline.points,
                startSite: polyline.startSite,
                endSite: polyline.endSite,
                splits: splitsByPolyline[polylineIndex] ?? []
            )
            guard rebuilt.points.count >= 2 else { continue }

            var previousNodeVertex: Int?
            for i in rebuilt.points.indices {
                guard let site = rebuilt.siteAt[i] else { continue }
                guard let thisNode = nodeID(forSite: site) else { continue }
                if let startIndex = previousNodeVertex,
                   let startSite = rebuilt.siteAt[startIndex],
                   let fromID = nodeID(forSite: startSite) {
                    var localGeom = Array(rebuilt.points[startIndex...i])
                    if let snappedStart = nodeLocal[fromID] {
                        localGeom[0] = snappedStart
                    }
                    if let snappedEnd = nodeLocal[thisNode] {
                        localGeom[localGeom.count - 1] = snappedEnd
                    }
                    localGeom = collapseLocal(localGeom)
                    let length = polylineLength(localGeom)
                    if fromID == thisNode && length < 1 { continue }
                    guard localGeom.count >= 2 else { continue }

                    let geometry = localGeom.map { projection.toCoordinate($0) }
                    let edge = GraphEdge(
                        id: nextEdgeID,
                        fromID: fromID,
                        toID: thisNode,
                        lengthMeters: length,
                        geometry: geometry,
                        facilityType: polyline.route.facilityType,
                        lts: polyline.route.lts,
                        name: Self.displayName(for: polyline.route),
                        sourceRouteID: polyline.route.id,
                        isConnector: false
                    )
                    edgesByID[nextEdgeID] = edge
                    adjacency[fromID, default: []].append(nextEdgeID)
                    if fromID != thisNode {
                        adjacency[thisNode, default: []].append(nextEdgeID)
                    }
                    nextEdgeID += 1
                }
                previousNodeVertex = i
            }
        }

        return (edgesByID, adjacency)
    }

    private func rebuildVertices(
        points: [LocalPoint],
        startSite: Int,
        endSite: Int,
        splits: [Split]
    ) -> (points: [LocalPoint], siteAt: [Int?]) {
        let grouped = Dictionary(grouping: splits, by: \.segmentIndex)
        var raw: [(point: LocalPoint, site: Int?)] = []

        func append(_ point: LocalPoint, site: Int?) {
            if let last = raw.last, last.point.distance(to: point) < 0.3 {
                if raw[raw.count - 1].site == nil {
                    raw[raw.count - 1].site = site
                }
                return
            }
            raw.append((point, site))
        }

        append(points[0], site: startSite)
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let segmentLength = a.distance(to: b)
            let extras = (grouped[i] ?? []).sorted { $0.t < $1.t }
            for split in extras {
                let distToA = split.t * segmentLength
                let distToB = (1 - split.t) * segmentLength
                if distToA < 0.5 || distToB < 0.5 {
                    append(split.point, site: split.siteIndex)
                    continue
                }
                append(split.point, site: split.siteIndex)
            }
            let endVertexSite: Int? = (i + 1 == points.count - 1) ? endSite : nil
            append(b, site: endVertexSite)
        }

        return (raw.map(\.point), raw.map(\.site))
    }

    private func collapseLocal(_ points: [LocalPoint]) -> [LocalPoint] {
        var result: [LocalPoint] = []
        for point in points {
            if let last = result.last, last.distance(to: point) < 0.01 { continue }
            result.append(point)
        }
        return result
    }

    private func polylineLength(_ points: [LocalPoint]) -> Double {
        var length = 0.0
        for i in 1..<points.count {
            length += points[i - 1].distance(to: points[i])
        }
        return length
    }

    private func average(_ points: [LocalPoint]) -> LocalPoint {
        var x = 0.0
        var y = 0.0
        for point in points {
            x += point.x
            y += point.y
        }
        let n = Double(max(points.count, 1))
        return LocalPoint(x: x / n, y: y / n)
    }

    private static func displayName(for route: BikeRoute) -> String {
        if let bikeway = route.bikewayName, !bikeway.isEmpty {
            return bikeway
        }
        return route.streetName
    }
}
