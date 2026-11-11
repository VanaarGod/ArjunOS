import SwiftUI
import JarvisCore

/// The crew as a graph: the boss on top, workers below, helpers under the worker that started them. Lines show who handed work
/// to whom; a dot travels along a line when a question, answer or note was just sent. Click an agent to open its chat; drag to
/// rearrange; right-click to open its browser, terminal or activity log.
struct CrewGraphView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let crew = model.crew
        let nodes = crew.workers.map { AgentGraphLayout.Node(id: $0.id, parent: $0.parent) }
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let base = AgentGraphLayout.positions(workers: nodes, size: geo.size)
                let spots = placed(base)
                ZStack {
                    EdgeLayer(edges: crew.edges, spots: spots, running: crew.isRunning)
                    ForEach(crew.agents) { agent in
                        GraphNodeView(agent: agent, focused: crew.focusedID == agent.id)
                            .position(spots[agent.id] ?? CGPoint(x: geo.size.width / 2, y: 40))
                            .gesture(DragGesture(minimumDistance: 6)
                                .onChanged { crew.dragNode(agent.id, by: $0.translation) }
                                .onEnded { _ in crew.endDrag(agent.id) })
                            .onTapGesture { crew.openPanel(agent.id, .chat) }
                            .contextMenu {
                                ForEach(PanelKind.allCases.filter { $0 != .notes }) { kind in
                                    Button { crew.openPanel(agent.id, kind) } label: { Label("Open \(kind.title.lowercased())", systemImage: kind.symbol) }
                                }
                            }
                    }
                }
            }
            .frame(height: AgentGraphLayout.idealHeight(workers: nodes, width: 760))
            legend
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func placed(_ base: [String: CGPoint]) -> [String: CGPoint] {
        var out = base
        for (id, offset) in model.crew.nodeOffsets { if let p = out[id] { out[id] = CGPoint(x: p.x + offset.width, y: p.y + offset.height) } }
        return out
    }

    private var legend: some View {
        HStack(spacing: 14) {
            key(Color.white.opacity(0.5), "hands out work")
            key(.orange, "question or answer")
            key(.teal, "shared note or peer question")
            key(Theme.accent, "started a helper")
            Spacer()
            if !model.crew.nodeOffsets.isEmpty {
                Button("Reset layout") { model.crew.nodeOffsets = [:] }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
            }
            Text("Click an agent to open it. Drag to move. Right-click for more.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
    private func key(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) { Capsule().fill(color).frame(width: 14, height: 3); Text(text).font(.caption2).foregroundStyle(.secondary) }
    }
}

/// All the lines, plus the dots travelling along them. Redrawn about 20 times a second while something is moving.
private struct EdgeLayer: View {
    let edges: [GraphEdge]
    let spots: [String: CGPoint]
    let running: Bool
    private static let travel: TimeInterval = 1.4

    var body: some View {
        let animating = running || edges.contains { ($0.lastPulse.map { Date().timeIntervalSince($0) } ?? 99) < Self.travel }
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animating)) { context in
            Canvas { gc, _ in
                for edge in edges {
                    guard let a = spots[edge.from], let b = spots[edge.to] else { continue }
                    let color = Self.color(edge.kind)
                    let control = Self.control(a, b, curved: edge.kind != .delegate)
                    var path = Path(); path.move(to: a); path.addQuadCurve(to: b, control: control)
                    let dashed = edge.kind == .peer || edge.kind == .spawn
                    gc.stroke(path, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dashed ? [5, 4] : []))
                    if let pulse = edge.lastPulse {
                        let t = context.date.timeIntervalSince(pulse) / Self.travel
                        if t >= 0 && t <= 1 {
                            let p = Self.point(a, control, b, CGFloat(t))
                            gc.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(color.opacity(0.25 * (1 - t))))
                            gc.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    static func color(_ k: GraphEdge.Kind) -> Color {
        switch k { case .delegate: .white; case .question: .orange; case .peer: .teal; case .spawn: Theme.accent }
    }
    /// A straight line for hand-outs; a gentle curve for the rest so they don't hide behind the straight ones.
    static func control(_ a: CGPoint, _ b: CGPoint, curved: Bool) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        guard curved else { return mid }
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        return CGPoint(x: mid.x - dy / len * 28, y: mid.y + dx / len * 28)
    }
    static func point(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

private struct GraphNodeView: View {
    let agent: CrewAgent
    let focused: Bool
    @State private var pulse = false

    var body: some View {
        let ring = stateColor
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color.white.opacity(agent.awake ? 0.16 : 0.07))
                Circle().strokeBorder(ring.opacity(0.9), lineWidth: focused ? 3 : 2)
                if let p = agent.progress, agent.progressTotal > 1, agent.state == "working" {
                    Circle().trim(from: 0, to: p).stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).padding(-5)
                }
                Image(systemName: agent.isBoss ? "crown.fill" : (agent.parent != nil && agent.parent != "boss" ? "person.badge.plus" : "person.fill"))
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(agent.isBoss ? Color.yellow : Color.white.opacity(0.9))
                Image(systemName: agent.awake ? "sun.max.fill" : "moon.zzz.fill").font(.system(size: 10)).foregroundStyle(agent.awake ? Color.yellow : Color.secondary)
                    .padding(3).background(Circle().fill(.black.opacity(0.55))).offset(x: 20, y: -20)
                if agent.state == "waiting_user" {
                    Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.white).padding(4).background(Circle().fill(Color.orange)).offset(x: -20, y: -20)
                }
            }
            .frame(width: 56, height: 56)
            .scaleEffect(agent.state == "working" && pulse ? 1.06 : 1)
            .shadow(color: ring.opacity(agent.state == "working" ? 0.6 : 0), radius: 10)
            .opacity(agent.awake || agent.state != "idle" ? 1 : 0.7)
            Text(agent.title).font(.caption.weight(.medium)).lineLimit(1).frame(maxWidth: 96)
            Text(agent.stateLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 100)
        .contentShape(Rectangle())
        .help(tooltip)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
        .animation(Theme.smooth, value: agent.state)
    }

    private var tooltip: String {
        var lines: [String] = ["\(agent.title): \(agent.stateLabel)"]
        var model = AppModel.shortModelName(crewModelName(agent.model))
        if agent.size == "large" { model += " (stronger model)" }
        lines.append(model)
        if agent.progressTotal > 1 { lines.append("\(agent.progressDone) of \(agent.progressTotal) parts") }
        if !agent.inputs.isEmpty { lines.append(agent.inputs.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private var stateColor: Color {
        switch agent.state {
        case "working": .green; case "done": Theme.accent; case "failed": .red; case "waiting_user": .orange; case "queued": .yellow; case "skipped": .gray; default: .secondary
        }
    }
}
