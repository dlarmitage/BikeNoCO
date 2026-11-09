import Foundation

/// Uniform grid hash for points and segments. Cell size is in the same units as `LocalPoint` (meters).
struct SpatialGrid<ID: Hashable> {
    let cellSize: Double

    private var pointCells: [Cell: [PointRecord]] = [:]
    private var segmentCells: [Cell: [SegmentRecord]] = [:]

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    private struct PointRecord {
        let id: ID
        let point: LocalPoint
    }

    private struct SegmentRecord {
        let id: ID
        let a: LocalPoint
        let b: LocalPoint
    }

    init(cellSize: Double = 25) {
        self.cellSize = cellSize
    }

    mutating func insertPoint(id: ID, at point: LocalPoint) {
        pointCells[cell(for: point), default: []].append(PointRecord(id: id, point: point))
    }

    mutating func insertSegment(id: ID, from a: LocalPoint, to b: LocalPoint) {
        let record = SegmentRecord(id: id, a: a, b: b)
        for cell in cellsAlong(a, b) {
            segmentCells[cell, default: []].append(record)
        }
    }

    func points(near query: LocalPoint, radius: Double) -> [(id: ID, point: LocalPoint, distance: Double)] {
        var seen: Set<ID> = []
        var results: [(id: ID, point: LocalPoint, distance: Double)] = []
        for cell in cellsOverlappingRadius(query, radius: radius) {
            guard let records = pointCells[cell] else { continue }
            for record in records {
                if seen.contains(record.id) { continue }
                let distance = query.distance(to: record.point)
                if distance <= radius {
                    seen.insert(record.id)
                    results.append((record.id, record.point, distance))
                }
            }
        }
        return results
    }

    func segments(near query: LocalPoint, radius: Double) -> [(id: ID, a: LocalPoint, b: LocalPoint, distance: Double)] {
        var seen: Set<ID> = []
        var results: [(id: ID, a: LocalPoint, b: LocalPoint, distance: Double)] = []
        for cell in cellsOverlappingRadius(query, radius: radius) {
            guard let records = segmentCells[cell] else { continue }
            for record in records {
                if seen.contains(record.id) { continue }
                let distance = query.projected(ontoSegmentFrom: record.a, to: record.b).distance
                if distance <= radius {
                    seen.insert(record.id)
                    results.append((record.id, record.a, record.b, distance))
                }
            }
        }
        return results
    }

    /// Segments stored in the cells this segment passes through (plus a 1-cell halo so
    /// crossings right on a grid corner are not missed).
    func segments(alongFrom a: LocalPoint, to b: LocalPoint) -> [(id: ID, a: LocalPoint, b: LocalPoint)] {
        var seen: Set<ID> = []
        var results: [(id: ID, a: LocalPoint, b: LocalPoint)] = []
        for cell in cellsAlong(a, b) {
            for dx in -1...1 {
                for dy in -1...1 {
                    let neighbor = Cell(x: cell.x + dx, y: cell.y + dy)
                    guard let records = segmentCells[neighbor] else { continue }
                    for record in records {
                        if seen.contains(record.id) { continue }
                        seen.insert(record.id)
                        results.append((record.id, record.a, record.b))
                    }
                }
            }
        }
        return results
    }

    private func cell(for point: LocalPoint) -> Cell {
        Cell(x: Int(floor(point.x / cellSize)), y: Int(floor(point.y / cellSize)))
    }

    private func cellsOverlappingRadius(_ query: LocalPoint, radius: Double) -> [Cell] {
        cellsOverlapping(
            minX: query.x - radius,
            minY: query.y - radius,
            maxX: query.x + radius,
            maxY: query.y + radius
        )
    }

    private func cellsOverlapping(minX: Double, minY: Double, maxX: Double, maxY: Double) -> [Cell] {
        let x0 = Int(floor(minX / cellSize))
        let x1 = Int(floor(maxX / cellSize))
        let y0 = Int(floor(minY / cellSize))
        let y1 = Int(floor(maxY / cellSize))
        var cells: [Cell] = []
        cells.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for x in x0...x1 {
            for y in y0...y1 {
                cells.append(Cell(x: x, y: y))
            }
        }
        return cells
    }

    /// Grid cells a segment actually passes through (Amanatides–Woo), not the bounding-box fill.
    private func cellsAlong(_ a: LocalPoint, _ b: LocalPoint) -> [Cell] {
        var x = Int(floor(a.x / cellSize))
        var y = Int(floor(a.y / cellSize))
        let xEnd = Int(floor(b.x / cellSize))
        let yEnd = Int(floor(b.y / cellSize))
        var cells = [Cell(x: x, y: y)]
        if x == xEnd && y == yEnd { return cells }

        let dx = b.x - a.x
        let dy = b.y - a.y
        let stepX = dx > 0 ? 1 : dx < 0 ? -1 : 0
        let stepY = dy > 0 ? 1 : dy < 0 ? -1 : 0
        let tDeltaX = stepX != 0 ? abs(cellSize / dx) : Double.infinity
        let tDeltaY = stepY != 0 ? abs(cellSize / dy) : Double.infinity

        var tMaxX: Double
        if stepX > 0 {
            tMaxX = (Double(x + 1) * cellSize - a.x) / dx
        } else if stepX < 0 {
            tMaxX = (Double(x) * cellSize - a.x) / dx
        } else {
            tMaxX = Double.infinity
        }

        var tMaxY: Double
        if stepY > 0 {
            tMaxY = (Double(y + 1) * cellSize - a.y) / dy
        } else if stepY < 0 {
            tMaxY = (Double(y) * cellSize - a.y) / dy
        } else {
            tMaxY = Double.infinity
        }

        let maxSteps = abs(xEnd - x) + abs(yEnd - y) + 2
        for _ in 0..<maxSteps {
            if x == xEnd && y == yEnd { break }
            if tMaxX < tMaxY {
                if tMaxX > 1 { break }
                x += stepX
                tMaxX += tDeltaX
            } else if tMaxY < tMaxX {
                if tMaxY > 1 { break }
                y += stepY
                tMaxY += tDeltaY
            } else {
                if tMaxX > 1 { break }
                x += stepX
                y += stepY
                tMaxX += tDeltaX
                tMaxY += tDeltaY
            }
            cells.append(Cell(x: x, y: y))
        }
        return cells
    }
}
