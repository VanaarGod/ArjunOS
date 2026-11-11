import Foundation
import CoreGraphics

/// Where each agent sits in the agent graph: the boss on top, its workers in a row below, and any helpers a worker started
/// below that worker. Pure geometry, so it can be tested without any UI.
public enum AgentGraphLayout {
    public struct Node: Equatable, Sendable {
        public var id: String
        public var parent: String?               // nil or "boss": started by the boss; otherwise the id of the worker that started it
        public init(id: String, parent: String? = nil) { self.id = id; self.parent = parent }
    }

    public static func positions(workers: [Node], size: CGSize, nodeRadius: CGFloat = 28, margin: CGFloat = 16) -> [String: CGPoint] {
        guard size.width > 0, size.height > 0 else { return [:] }
        let ids = Set(workers.map(\.id))
        let top = workers.filter { $0.parent == nil || $0.parent == "boss" || !ids.contains($0.parent ?? "") }
        let kids = workers.filter { n in !top.contains(where: { $0.id == n.id }) }
        let labelRoom: CGFloat = 38                                                  // each node has a name under it
        let usableW = max(size.width - 2 * (margin + nodeRadius), 1)
        let rows: CGFloat = kids.isEmpty ? 1 : 2
        let topY = margin + nodeRadius
        let gap = max(nodeRadius * 2 + labelRoom, min(130, (size.height - 2 * (margin + nodeRadius) - labelRoom) / max(rows, 1)))

        var out: [String: CGPoint] = ["boss": CGPoint(x: size.width / 2, y: topY)]
        let n = CGFloat(top.count)
        let step = n > 0 ? usableW / n : usableW
        let crowded = step < nodeRadius * 2 + 22                                      // too tight for one row: zig-zag the nodes up and down
        for (i, node) in top.enumerated() {
            let x = margin + nodeRadius + step * (CGFloat(i) + 0.5)
            let y = topY + gap + (crowded && i % 2 == 1 ? nodeRadius + labelRoom * 0.75 : 0)
            out[node.id] = CGPoint(x: x, y: y)
        }
        var byParent: [String: [Node]] = [:]
        for k in kids { byParent[k.parent ?? "", default: []].append(k) }
        for (parent, list) in byParent {
            let base = out[parent] ?? CGPoint(x: size.width / 2, y: topY + gap)
            let spacing = nodeRadius * 2 + 20
            for (j, node) in list.enumerated() {
                let x = base.x + (CGFloat(j) - CGFloat(list.count - 1) / 2) * spacing
                let y = base.y + gap * 0.9
                out[node.id] = CGPoint(x: min(max(x, margin + nodeRadius), size.width - margin - nodeRadius), y: y)
            }
        }
        return out
    }

    /// The height the graph needs for this many rows of agents.
    public static func idealHeight(workers: [Node], width: CGFloat, nodeRadius: CGFloat = 28) -> CGFloat {
        let ids = Set(workers.map(\.id))
        let top = workers.filter { $0.parent == nil || $0.parent == "boss" || !ids.contains($0.parent ?? "") }
        let hasKids = top.count < workers.count
        let step = top.isEmpty ? width : (width - 2 * (16 + nodeRadius)) / CGFloat(top.count)
        let zigzag = step < nodeRadius * 2 + 22 && top.count > 1
        let rows: CGFloat = hasKids ? 3 : 2
        return 16 + nodeRadius * 2 + (rows - 1) * 110 + 38 + (zigzag ? nodeRadius + 30 : 0) + 20
    }
}
