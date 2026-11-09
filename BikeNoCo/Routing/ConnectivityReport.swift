import Foundation
import CoreLocation

struct ConnectivityReport {
    struct GapCandidate {
        let danglingCoordinate: CLLocationCoordinate2D
        let otherCoordinate: CLLocationCoordinate2D
        let distanceMeters: Double
    }

    let nodeCount: Int
    let edgeCount: Int
    let componentCount: Int
    let largestComponentLengthShare: Double
    let crossingCount: Int
    let gapCandidates: [GapCandidate]
    let totalLengthMeters: Double

    var summary: String {
        let sharePercent = largestComponentLengthShare * 100
        return """
        [BikeNoCo Graph] === Bike network connectivity ===
        [BikeNoCo Graph] nodes: \(nodeCount)
        [BikeNoCo Graph] edges: \(edgeCount)
        [BikeNoCo Graph] components: \(componentCount)
        [BikeNoCo Graph] largest component: \(String(format: "%.1f", sharePercent))% of total edge length
        [BikeNoCo Graph] x-crossings: \(crossingCount)
        [BikeNoCo Graph] gap candidates: \(gapCandidates.count)
        [BikeNoCo Graph] total length: \(String(format: "%.1f", totalLengthMeters)) m
        """
    }

    static func make(
        from graph: BikeNetworkGraph,
        gapSearchMeters: Double = 25
    ) -> ConnectivityReport {
        let nodeCount = graph.nodesByID.count
        let edgeCount = graph.edgesByID.count
        let totalLength = graph.edgesByID.values.reduce(0.0) { $0 + $1.lengthMeters }

        let (componentCount, componentOf, largestShare) = components(in: graph, totalLength: totalLength)
        let crossingCount = countCrossings(in: graph)
        let gaps = gapCandidates(in: graph, componentOf: componentOf, radius: gapSearchMeters)

        return ConnectivityReport(
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            componentCount: componentCount,
            largestComponentLengthShare: largestShare,
            crossingCount: crossingCount,
            gapCandidates: gaps,
            totalLengthMeters: totalLength
        )
    }

    private static func components(
        in graph: BikeNetworkGraph,
        totalLength: Double
    ) -> (count: Int, componentOf: [Int: Int], largestShare: Double) {
        let nodeIDs = Array(graph.nodesByID.keys)
        guard !nodeIDs.isEmpty else {
            return (0, [:], 0)
        }

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

        var componentOf: [Int: Int] = [:]
        var roots: Set<Int> = []
        for (i, id) in nodeIDs.enumerated() {
            let root = uf.find(i)
            roots.insert(root)
            componentOf[id] = root
        }

        var lengthByRoot: [Int: Double] = [:]
        for edge in graph.edgesByID.values {
            if let root = componentOf[edge.fromID] {
                lengthByRoot[root, default: 0] += edge.lengthMeters
            }
        }
        let largest = lengthByRoot.values.max() ?? 0
        let share = totalLength > 0 ? largest / totalLength : 0
        return (roots.count, componentOf, share)
    }

    private struct EdgeSegmentID: Hashable {
        let edgeID: Int
        let segmentIndex: Int
    }

    private static func countCrossings(in graph: BikeNetworkGraph) -> Int {
        let projection = graph.projection
        var grid = SpatialGrid<EdgeSegmentID>(cellSize: 25)
        var localGeometry: [Int: [LocalPoint]] = [:]

        for edge in graph.edgesByID.values {
            let points = edge.geometry.map { projection.toLocal($0) }
            localGeometry[edge.id] = points
            for i in 0..<(points.count - 1) {
                grid.insertSegment(
                    id: EdgeSegmentID(edgeID: edge.id, segmentIndex: i),
                    from: points[i],
                    to: points[i + 1]
                )
            }
        }

        var crossingPairs: Set<EdgePair> = []
        for edge in graph.edgesByID.values {
            guard let points = localGeometry[edge.id] else { continue }
            for i in 0..<(points.count - 1) {
                let a1 = points[i]
                let a2 = points[i + 1]
                let candidates = grid.segments(alongFrom: a1, to: a2)
                for candidate in candidates {
                    if candidate.id.edgeID <= edge.id { continue }
                    guard let other = graph.edgesByID[candidate.id.edgeID] else { continue }
                    if sharesNode(edge, other) { continue }
                    if LocalProjection.properIntersection(a1: a1, a2: a2, b1: candidate.a, b2: candidate.b) != nil {
                        crossingPairs.insert(EdgePair(a: edge.id, b: other.id))
                    }
                }
            }
        }
        return crossingPairs.count
    }

    private static func sharesNode(_ a: GraphEdge, _ b: GraphEdge) -> Bool {
        a.fromID == b.fromID || a.fromID == b.toID || a.toID == b.fromID || a.toID == b.toID
    }

    private static func gapCandidates(
        in graph: BikeNetworkGraph,
        componentOf: [Int: Int],
        radius: Double
    ) -> [GapCandidate] {
        let projection = graph.projection
        var degree: [Int: Int] = [:]
        for edge in graph.edgesByID.values {
            if edge.fromID == edge.toID {
                degree[edge.fromID, default: 0] += 2
            } else {
                degree[edge.fromID, default: 0] += 1
                degree[edge.toID, default: 0] += 1
            }
        }

        var nodeLocal: [Int: LocalPoint] = [:]
        var pointGrid = SpatialGrid<Int>(cellSize: 25)
        for node in graph.nodesByID.values {
            let local = projection.toLocal(node.coordinate)
            nodeLocal[node.id] = local
            pointGrid.insertPoint(id: node.id, at: local)
        }

        var segmentGrid = SpatialGrid<Int>(cellSize: 25)
        for edge in graph.edgesByID.values {
            let points = edge.geometry.map { projection.toLocal($0) }
            for i in 0..<(points.count - 1) {
                segmentGrid.insertSegment(id: edge.id, from: points[i], to: points[i + 1])
            }
        }

        var bestByKey: [SymmetricGapKey: GapCandidate] = [:]
        for (nodeID, nodeDegree) in degree where nodeDegree == 1 {
            guard let origin = nodeLocal[nodeID],
                  let originComponent = componentOf[nodeID],
                  let originNode = graph.nodesByID[nodeID] else { continue }

            var bestDistance = radius
            var bestPoint: LocalPoint?

            for hit in pointGrid.points(near: origin, radius: radius) {
                if hit.id == nodeID { continue }
                guard let otherComponent = componentOf[hit.id], otherComponent != originComponent else { continue }
                if hit.distance < bestDistance {
                    bestDistance = hit.distance
                    bestPoint = hit.point
                }
            }

            for hit in segmentGrid.segments(near: origin, radius: radius) {
                guard let edge = graph.edgesByID[hit.id],
                      let otherComponent = componentOf[edge.fromID],
                      otherComponent != originComponent else { continue }
                let projected = origin.projected(ontoSegmentFrom: hit.a, to: hit.b)
                if projected.distance < bestDistance {
                    bestDistance = projected.distance
                    bestPoint = projected.point
                }
            }

            guard let bestPoint else { continue }
            let otherCoordinate = projection.toCoordinate(bestPoint)
            let candidate = GapCandidate(
                danglingCoordinate: originNode.coordinate,
                otherCoordinate: otherCoordinate,
                distanceMeters: bestDistance
            )
            let key = SymmetricGapKey(originNode.coordinate, otherCoordinate)
            if let existing = bestByKey[key], existing.distanceMeters <= candidate.distanceMeters {
                continue
            }
            bestByKey[key] = candidate
        }

        return bestByKey.values.sorted { $0.distanceMeters < $1.distanceMeters }
    }
}

/// Quantized, order-independent key so A→B and B→A collapse to one gap candidate.
private struct SymmetricGapKey: Hashable {
    let aLat: Int
    let aLon: Int
    let bLat: Int
    let bLon: Int

    init(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) {
        // ~1 m quantization near 40.5 N.
        let q1 = (lat: Int((c1.latitude * 111_000).rounded()), lon: Int((c1.longitude * 85_000).rounded()))
        let q2 = (lat: Int((c2.latitude * 111_000).rounded()), lon: Int((c2.longitude * 85_000).rounded()))
        if (q1.lat, q1.lon) <= (q2.lat, q2.lon) {
            aLat = q1.lat; aLon = q1.lon; bLat = q2.lat; bLon = q2.lon
        } else {
            aLat = q2.lat; aLon = q2.lon; bLat = q1.lat; bLon = q1.lon
        }
    }
}

private struct EdgePair: Hashable {
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
