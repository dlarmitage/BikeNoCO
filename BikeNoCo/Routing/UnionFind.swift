import Foundation

struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    @discardableResult
    mutating func add() -> Int {
        let id = parent.count
        parent.append(id)
        rank.append(0)
        return id
    }

    mutating func find(_ x: Int) -> Int {
        guard parent.indices.contains(x) else { return x }
        if parent[x] != x {
            parent[x] = find(parent[x])
        }
        return parent[x]
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra == rb { return }
        guard parent.indices.contains(ra), parent.indices.contains(rb) else { return }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else if rank[ra] > rank[rb] {
            parent[rb] = ra
        } else {
            parent[rb] = ra
            rank[ra] += 1
        }
    }
}
