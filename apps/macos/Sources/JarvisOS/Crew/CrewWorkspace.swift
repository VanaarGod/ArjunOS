import SwiftUI
import JarvisCore

/// The multi-panel workspace: up to four panels side by side, each showing one agent as a chat, its own browser, its own terminal,
/// its activity log, or the team's shared notes.
struct CrewWorkspace: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let crew = model.crew
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Workspace", systemImage: "rectangle.split.2x2").font(.headline)
                Spacer()
                Menu {
                    ForEach(crew.agents) { agent in
                        Menu(agent.title) {
                            ForEach(PanelKind.allCases.filter { $0 != .notes && !(agent.isBoss && $0 == .browser) }) { kind in
                                Button { crew.openPanel(agent.id, kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                            }
                        }
                    }
                    Divider()
                    Button { crew.openPanel("boss", .notes) } label: { Label("Team notes", systemImage: PanelKind.notes.symbol) }
                } label: { Label("Open panel", systemImage: "plus.rectangle.on.rectangle") }
                    .menuStyle(.borderlessButton).fixedSize()
                if !crew.panels.isEmpty { Button("Close all") { crew.panels = [] }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary) }
            }
            if crew.panels.isEmpty {
                Text("Click an agent in the graph, or use “Open panel”, to see it here. You can keep up to four panels open side by side.")
                    .font(.callout).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(crew.panels) { panel in PanelView(panel: panel) }
                }
            }
        }
    }
}

private struct PanelView: View {
    @Environment(AppModel.self) private var model
    let panel: WorkspacePanel

    var body: some View {
        let crew = model.crew
        let agent = crew.agents.first { $0.id == panel.agentID }
        let focused = crew.focusedID == panel.agentID
        VStack(alignment: .leading, spacing: 10) {
            header(agent)
            Group {
                if let agent {
                    switch panel.kind {
                    case .chat: ChatPanel(agent: agent)
                    case .browser: BrowserPanel(agent: agent)
                    case .terminal: TerminalPanel(agent: agent)
                    case .log: LogPanel(agent: agent)
                    case .notes: NotesPanel()
                    }
                } else { Text("This agent is no longer in the crew.").font(.callout).foregroundStyle(.secondary) }
            }
            .frame(height: 380)
        }
        .padding(12)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: focused ? Theme.accent.opacity(0.10) : nil)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.55) : Theme.hairline))
        .onTapGesture { crew.focusedID = panel.agentID }
    }

    private func header(_ agent: CrewAgent?) -> some View {
        let crew = model.crew
        return HStack(spacing: 8) {
            if let agent {
                Image(systemName: agent.awake ? "sun.max.fill" : "moon.zzz.fill").font(.caption).foregroundStyle(agent.awake ? Color.yellow : Color.secondary)
                    .help(agent.awake ? "Its model is awake in memory" : "Its model is asleep (not using memory)")
                Text(panel.kind == .notes ? "Team notes" : agent.title).font(.headline).lineLimit(1)
                if panel.kind != .notes {
                    Text(AppModel.shortModelName(crewModelName(agent.model))).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Circle().fill(color(agent.state)).frame(width: 7, height: 7)
                    Text(agent.stateLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else { Text("Agent").font(.headline) }
            Spacer()
            Menu {
                ForEach(PanelKind.allCases.filter { !(agent?.isBoss == true && $0 == .browser) }) { kind in
                    Button { crew.setPanelKind(panel.id, kind) } label: { if kind == panel.kind { Label(kind.title, systemImage: "checkmark") } else { Label(kind.title, systemImage: kind.symbol) } }
                }
            } label: { Image(systemName: panel.kind.symbol) }
                .menuStyle(.borderlessButton).fixedSize().help("Show this agent as…")
            Button { crew.closePanel(panel.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).help("Close this panel")
        }
    }

    private func color(_ state: String) -> Color {
        switch state { case "working": .green; case "done": Theme.accent; case "failed": .red; case "waiting_user": .orange; case "queued": .yellow; default: .secondary }
    }
}

// MARK: - Chat

private struct ChatPanel: View {
    @Environment(AppModel.self) private var model
    let agent: CrewAgent
    @State private var draft = ""

    var body: some View {
        let crew = model.crew
        let working = crew.isRunning && (agent.isBoss || ["queued", "working", "waiting_user"].contains(agent.state))
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        workBlock
                        ForEach(agent.chat) { m in
                            MessageRow(message: m, name: agent.title, streaming: agent.chatBusy && m.id == agent.chat.last?.id).id(m.id)
                        }
                        Color.clear.frame(height: 4).id("end")
                    }.padding(.trailing, 6)
                }
                .onChange(of: agent.chat.last?.content) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: agent.message.content) { _, _ in if agent.chat.isEmpty { proxy.scrollTo("end", anchor: .bottom) } }
            }
            if !agent.problems.isEmpty && agent.state != "done" {
                Label(agent.problems.last ?? "", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField(working ? "Message \(agent.title) (it reads this at its next step)" : "Ask \(agent.title) about its work", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...3).onSubmit(send)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                    .buttonStyle(GlassCircleButtonStyle(tint: draft.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Theme.accent.opacity(0.8), size: 28))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || (agent.chatBusy && !working))
            }
            if !working && !agent.isBoss && agent.state == "queued" { Text("This agent hasn't started yet.").font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    /// What the agent did on its job: the live output while it works, its finished report afterwards (the boss: its final answer).
    @ViewBuilder private var workBlock: some View {
        let crew = model.crew
        if agent.isBoss {
            if !crew.finalText.isEmpty { MessageRow(message: ChatMessage(role: "assistant", content: crew.finalText), name: "Boss", streaming: false) }
            else { Text(agent.detail.isEmpty ? (crew.isRunning ? "Waiting for the workers…" : "") : "Boss: \(agent.detail)…").font(.callout).foregroundStyle(.secondary) }
        } else if !agent.report.isEmpty {
            MessageRow(message: ChatMessage(role: "assistant", content: agent.report), name: agent.title, streaming: false)
        } else if agent.message.content.isEmpty && (agent.message.activity?.isEmpty ?? true) {
            Text(agent.state == "queued" ? "Waiting for its turn." : (agent.state == "failed" ? agent.detail : "Starting…")).font(.callout).foregroundStyle(.secondary)
        } else {
            MessageRow(message: agent.message, name: agent.title, streaming: agent.state == "working")
        }
    }

    private func send() {
        let t = draft
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        draft = ""
        model.crew.send(to: agent, text: t)
    }
}

// MARK: - Browser

private struct BrowserPanel: View {
    let agent: CrewAgent
    var body: some View {
        if let b = agent.browser {
            VStack(alignment: .leading, spacing: 6) {
                BrowserPane().environment(b)
                Text("This agent's own browser: separate from yours and not signed in to anything. A page you open here is what this agent reads next.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "safari").font(.title).foregroundStyle(.tertiary)
                Text("The boss doesn't browse. Its workers do, each in its own browser.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Terminal

private struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    let agent: CrewAgent
    @State private var command = ""

    private var agentRuns: [MessageActivity] { (agent.message.activity ?? []).filter { $0.kind == "shell" } }

    var body: some View {
        let enabled = agent.terminalInfo?.enabled ?? true
        VStack(alignment: .leading, spacing: 8) {
            if let info = agent.terminalInfo, info.enabled {
                Text("Private workspace: " + (info.workspace ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if agentRuns.isEmpty && agent.terminal.isEmpty {
                            Text(enabled ? "Nothing has run here yet. When \(agent.title) runs a command it appears below (you approve it first). You can also type your own commands."
                                         : "The terminal is turned off in Settings.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(agentRuns) { run in AgentRunBlock(run: run) }
                        if !agent.terminal.isEmpty {
                            if !agentRuns.isEmpty { Divider().opacity(0.3) }
                            ForEach(agent.terminal) { line in lineView(line) }
                        }
                        Color.clear.frame(height: 2).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .onChange(of: agent.terminal.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .padding(10).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if enabled {
                HStack(spacing: 6) {
                    Text("$").font(.system(.callout, design: .monospaced)).foregroundStyle(.green)
                    TextField("ls, cat notes.txt, node script.js …", text: $command).textFieldStyle(.plain).font(.system(.callout, design: .monospaced)).onSubmit(run)
                    if agent.terminalBusy { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let allowed = agent.terminalInfo?.allowed {
                    Text("Allowed: " + allowed.joined(separator: " ") + ". No deleting, pipes or redirects. Runs in a sandbox.").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
        }
        .task { await model.crew.loadTerminal(agent) }
    }

    private func run() {
        let c = command
        command = ""
        model.crew.runCommand(agent, c)
    }

    private func lineView(_ line: TerminalLine) -> some View {
        Group {
            switch line.kind {
            case .command: Text("$ " + line.text).foregroundStyle(Color.green)
            case .output: Text(line.text).foregroundStyle(Color.primary.opacity(0.9))
            case .error: Text(line.text).foregroundStyle(Color.orange)
            case .info: Text(line.text).foregroundStyle(Color.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One command the agent itself ran: what it ran, whether it was approved, and what came out.
private struct AgentRunBlock: View {
    let run: MessageActivity
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("$ " + (run.detail ?? run.title)).foregroundStyle(Color.green)
                if run.status == "waiting_approval" { Text("waiting for your approval").foregroundStyle(Color.orange) }
                else if run.status == "running" { Text("running…").foregroundStyle(.secondary) }
                else if let code = run.exitCode, code != 0 { Text("exit \(code)").foregroundStyle(Color.orange) }
            }
            if let out = run.output, !out.isEmpty { Text(out).foregroundStyle(Color.primary.opacity(0.85)) }
        }
        .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Activity log

private struct LogPanel: View {
    let agent: CrewAgent
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if agent.progressTotal > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: agent.progress ?? 0)
                        Text("\(agent.progressDone) of \(agent.progressTotal) parts of its material read").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !agent.instructions.isEmpty { Text("Job: " + agent.instructions).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if !agent.inputs.isEmpty { Label(agent.inputs.joined(separator: ", "), systemImage: "doc.text").font(.caption).foregroundStyle(.secondary) }
                Divider().opacity(0.3)
                if agent.log.isEmpty { Text("Nothing has happened yet.").font(.caption).foregroundStyle(.secondary) }
                ForEach(agent.log) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.icon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                            Text(item.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                ForEach(Array(agent.problems.enumerated()), id: \.offset) { _, p in
                    Label(p, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }
}

// MARK: - Shared team notes

private struct NotesPanel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let board = model.crew.blackboard
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What the whole team shares. The boss sets the rules and terms; any worker can add facts. Every worker sees all of it before each step, which is how their reports end up using the same names, units and formats.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let board {
                    section("Rules", board.conventions.map { ($0, "") })
                    section("Terms", board.glossary.map { ($0.term, $0.meaning) })
                    section("Facts shared by workers", board.facts.map { ($0.key + " = " + $0.value, "from " + $0.agent) })
                    if board.conventions.isEmpty && board.glossary.isEmpty && board.facts.isEmpty { Text("Nothing shared yet.").font(.caption).foregroundStyle(.tertiary) }
                } else { Text("Nothing shared yet.").font(.caption).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.0).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if !row.1.isEmpty { Text(row.1).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}
