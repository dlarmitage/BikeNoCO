import XCTest
@testable import BikeNoCo

final class UnionFindTests: XCTestCase {
    func testOutOfBoundsFindDoesNotTrap() {
        var uf = UnionFind(count: 3)
        // Previously parent[x] would EXC_BREAKPOINT on a bad index.
        XCTAssertEqual(uf.find(99), 99)
        uf.union(0, 99) // must no-op without trapping
        XCTAssertEqual(uf.find(0), 0)
        uf.union(0, 1)
        XCTAssertEqual(uf.find(0), uf.find(1))
    }
}
