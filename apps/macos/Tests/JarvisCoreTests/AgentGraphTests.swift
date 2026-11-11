import XCTest
@testable import JarvisCore

final class AgentGraphTests: XCTestCase {
    private func nodes(_ n: Int) -> [AgentGraphLayout.Node] { (1...max(n, 1)).map { AgentGraphLayout.Node(id: "w\($0)") } }
    private let size = CGSize(width: 900, height: 340)

    func testTheBossIsCenteredOnTopAndWorkersRunLeftToRightBelowIt() {
        let p = AgentGraphLayout.positions(workers: nodes(4), size: size)
        XCTAssertEqual(p["boss"]?.x ?? 0, 450, accuracy: 0.5)
        let xs = (1...4).compactMap { p["w\($0)"]?.x }; XCTAssertEqual(xs, xs.sorted())
        XCTAssertTrue((1...4).allSatisfy { (p["w\($0)"]?.y ?? 0) > (p["boss"]?.y ?? 0) + 60 })
    }

    func testEveryNodeStaysInsideTheCanvasAndNothingOverlaps() {
        for count in [1, 3, 7, 12] {
            let p = AgentGraphLayout.positions(workers: nodes(count), size: size)
            XCTAssertEqual(p.count, count + 1)
            for (id, pt) in p { XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 28, dy: 20).contains(pt), "\(id) at \(pt) with \(count) workers") }
            let pts = Array(p.values)
            for i in 0..<pts.count { for j in (i + 1)..<pts.count { XCTAssertGreaterThan(hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y), 50, "\(count) workers: nodes overlap") } }
        }
    }

    func testHelpersSitBelowTheWorkerThatStartedThem() {
        let ns = nodes(2) + [AgentGraphLayout.Node(id: "w3", parent: "w1"), AgentGraphLayout.Node(id: "w4", parent: "w1"), AgentGraphLayout.Node(id: "w5", parent: "boss")]
        let p = AgentGraphLayout.positions(workers: ns, size: CGSize(width: 900, height: 420))
        let parent = p["w1"]!
        for id in ["w3", "w4"] { XCTAssertGreaterThan(p[id]!.y, parent.y + 60); XCTAssertEqual(p[id]!.x, parent.x, accuracy: 60) }
        XCTAssertEqual(p["w5"]!.y, p["w1"]!.y, accuracy: 1)                              // started by the boss: same row as the first workers
    }

    func testAHelperWhoseParentIsUnknownStillGetsAPlace() {
        let p = AgentGraphLayout.positions(workers: [AgentGraphLayout.Node(id: "w1", parent: "w99")], size: size)
        XCTAssertNotNil(p["w1"]); XCTAssertNotNil(p["boss"])
    }

    func testDegenerateSizesAndEmptyCrews() {
        XCTAssertTrue(AgentGraphLayout.positions(workers: nodes(2), size: .zero).isEmpty)
        XCTAssertEqual(AgentGraphLayout.positions(workers: [], size: size).keys.sorted(), ["boss"])
        XCTAssertGreaterThan(AgentGraphLayout.idealHeight(workers: nodes(3), width: 800), 200)
        XCTAssertGreaterThan(AgentGraphLayout.idealHeight(workers: nodes(12), width: 500), AgentGraphLayout.idealHeight(workers: nodes(2), width: 800))
    }
}
