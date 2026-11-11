import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import JarvisCore

/// One agent in the crew: the boss, or a worker. Each worker has its OWN isolated browser (own cookies, own tabs).
@MainActor @Observable
final class CrewAgent: Identifiable {
    let id: String                          // "boss", "w1", "w2", ...
    var title: String
    var model: String                       // "endpoint|model"
    var state = "idle"                      // idle | queued | working | waiting_user | done | failed | skipped
    var detail = ""
    var message = ChatMessage(role: "assistant", content: "")        // live output, rendered with the normal chat renderer
    var report = ""                          // the finished, full report
    var problems: [String] = []
    var inputs: [String] = []
    var instructions = ""
    var parent: String?                      // who started it: nil/"boss" = the boss, otherwise the worker that asked for a helper
    var size = "small"                       // the boss's hint: "large" = a stronger model was asked for
    var progressDone = 0                     // parts of its material finished
    var progressTotal = 0
    var chat: [ChatMessage] = []             // your follow-up conversation with this agent
    var chatBusy = false
    var terminal: [TerminalLine] = []        // commands YOU ran in this agent's terminal
    var terminalInfo: CrewTerminalInfo?
    var terminalBusy = false
    var log: [CrewModel.TimelineItem] = []   // everything that happened to this agent
    @ObservationIgnored var chatTask: Task<Void, Never>?
    var progress: Double? { progressTotal > 0 ? Double(progressDone) / Double(progressTotal) : nil }
    var awake = false                        // is this agent's model in memory right now?
    var loading = false
    let isBoss: Bool
    let browser: BrowserModel?
    @ObservationIgnored var pushTask: Task<Void, Never>?

    init(id: String, title: String, model: String, isBoss: Bool, browser: BrowserModel?) {
        self.id = id; self.title = title; self.model = model; self.isBoss = isBoss; self.browser = browser
    }

    var stateLabel: String {
        if loading { return "Waking up…" }
        switch state {
        case "queued": return awake ? "Waiting for a turn" : "Waiting (asleep)"
        case "working": return "Working"
        case "waiting_user": return "Needs you"
        case "done": return "Done"
        case "failed": return "Failed"
        case "skipped": return "Skipped"
        default: return isBoss ? (awake ? "Awake" : "Asleep") : "Ready"
        }
    }
}

/// One line in an agent's terminal panel.
struct TerminalLine: Identifiable {
    enum Kind { case command, output, error, info }
    let id = UUID()
    var kind: Kind
    var text: String
}

enum PanelKind: String, CaseIterable, Identifiable {
    case chat, browser, terminal, log, notes
    var id: String { rawValue }
    var title: String { switch self { case .chat: "Chat"; case .browser: "Browser"; case .terminal: "Terminal"; case .log: "Activity"; case .notes: "Team notes" } }
    var symbol: String { switch self { case .chat: "bubble.left.and.bubble.right"; case .browser: "safari"; case .terminal: "terminal"; case .log: "list.bullet.rectangle"; case .notes: "note.text" } }
}

/// One panel in the workspace: one agent seen as chat, browser, terminal, activity log, or the shared team notes.
struct WorkspacePanel: Identifiable, Equatable {
    let id = UUID()
    var agentID: String
    var kind: PanelKind
}

/// A line between two agents in the graph. `lastPulse` makes a dot travel along it when something was just sent.
struct GraphEdge: Identifiable, Equatable {
    enum Kind { case delegate, question, peer, spawn }
    let id: String
    let from: String
    let to: String
    let kind: Kind
    var lastPulse: Date?
}

@MainActor @Observable
final class CrewModel {
    struct InputFile: Identifiable {
        enum State: Equatable { case reading, ready, failed(String) }
        let id = UUID()
        var name: String
        var kind = "text"
        var text = ""
        var images: [String] = []
        var bytes = 0
        var pages: Int?
        var workerModel: String?             // nil = automatic
        var note: String?
        var state: State = .reading
        var scanned: Bool { !images.isEmpty && kind == "pdf" }
    }
    struct TimelineItem: Identifiable { let id = UUID(); var icon: String; var text: String; var who: String; var at = Date() }
    enum Phase { case idle, running, finished }

    // setup
    var task = ""
    var bossRef: String?
    var workerRef: String?                   // nil = pick the smallest capable model automatically
    var preference: CrewPreference = .auto
    var maxWorkers = 4
    var review = true                        // the boss reviews finished reports before writing the final answer
    var files: [InputFile] = []
    // machine
    var resources: SystemResources?
    var preview: CrewPreview?
    var previewError: String?
    // live run
    var phase: Phase = .idle
    var agents: [CrewAgent] = []
    var memory: CrewMemory?
    var plan: CrewPlanInfo?
    var conventions: [String] = []
    var timeline: [TimelineItem] = []
    var needsUser: [CrewEvent.NeedsUser] = []
    var finalText = ""
    var contextText = ""
    var error: String?
    var focusedID: String?
    var panels: [WorkspacePanel] = []
    var edges: [GraphEdge] = []
    var blackboard: CrewBlackboard?
    var nodeOffsets: [String: CGSize] = [:]          // where you dragged nodes in the graph
    @ObservationIgnored private var dragBase: [String: CGSize] = [:]
    static let maxPanels = 4

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var crewID: String?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var browseTasks: [Task<Void, Never>] = []

    var boss: CrewAgent? { agents.first { $0.isBoss } }
    var workers: [CrewAgent] { agents.filter { !$0.isBoss } }
    var isRunning: Bool { phase == .running }
    var filesReady: Bool { !files.isEmpty && files.allSatisfy { $0.state == .ready } }
    var filesReading: Bool { files.contains { $0.state == .reading } }
    var canStart: Bool { !isRunning && bossRef != nil && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !filesReading }

    func attach(_ app: AppModel) {
        self.app = app
        if bossRef == nil { bossRef = app.selectedModelKey }
    }

    // MARK: machine and preview

    func refreshResources() async {
        guard let c = app?.bridge else { return }
        if let r = try? await c.systemResources() { resources = r }
    }

    func schedulePreview() {
        previewTask?.cancel()
        guard !isRunning, let boss = bossRef, app?.bridge != nil else { preview = nil; return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, let c = self.app?.bridge else { return }
            let inputs = self.files.filter { $0.state == .ready }.map {
                CrewRequest.Input(name: $0.name, kind: $0.kind, text: "", imagesB64: $0.images.isEmpty ? [] : ["-"], workerModel: $0.workerModel)
            }
            let req = CrewRequest(task: self.task.isEmpty ? "preview" : self.task, boss: boss, workerModel: self.workerRef, inputs: inputs,
                                  preference: self.preference.rawValue, maxWorkers: self.maxWorkers)
            do { self.preview = try await c.crewPreview(req); self.previewError = nil }
            catch { self.preview = nil; self.previewError = error.localizedDescription }
        }
    }

    // MARK: files

    func pickFiles() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.message = "Choose the files for the crew to read"
        if p.runModal() == .OK { addFiles(p.urls) }
    }

    func addFiles(_ urls: [URL]) {
        for url in urls.prefix(12 - files.count) { Task { await readFile(url) } }
    }

    func removeFile(_ id: UUID) { files.removeAll { $0.id == id }; schedulePreview() }
    func setWorkerModel(_ id: UUID, _ ref: String?) { if let i = files.firstIndex(where: { $0.id == id }) { files[i].workerModel = ref; schedulePreview() } }

    private func readFile(_ url: URL) async {
        guard let c = app?.bridge else { return }
        var f = InputFile(name: url.lastPathComponent)
        files.append(f); let id = f.id
        func update(_ change: (inout InputFile) -> Void) { if let i = files.firstIndex(where: { $0.id == id }) { change(&files[i]) } }
        let limit = AppModel.maxFileBytes
        let data: Data? = await Task.detached(priority: .userInitiated) {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if v?.isDirectory == true || (v?.fileSize ?? 0) > limit { return nil }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard let data else { update { $0.state = .failed("Couldn't read this file (folders and files over \(limit / 1_048_576) MB aren't supported).") }; return }
        update { $0.bytes = data.count }
        f.bytes = data.count
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        if isImage {
            let b64 = await Task.detached { ImageProcessor.jpegBase64(from: data) }.value
            guard let b64 else { update { $0.state = .failed("This image couldn't be read.") }; return }
            update { $0.kind = "image"; $0.images = [b64]; $0.state = .ready }
            schedulePreview(); return
        }
        do {
            let ex = try await c.extractFile(name: url.lastPathComponent, data: data)
            let isPDF = ex.kind == "pdf"
            var pages: Int?
            var images: [String] = []
            var note = ex.warning
            if isPDF, let doc = PDFDocument(data: data) {
                pages = doc.pageCount
                if ex.chars / max(doc.pageCount, 1) < 150 {                    // little or no text: a scan. Render the pages for a vision model.
                    images = await Self.renderPages(doc, max: 24)
                    note = (note.map { $0 + " " } ?? "") + (doc.pageCount > 24 ? "Scanned: only the first 24 of \(doc.pageCount) pages are read by vision." : "Scanned: pages are read by a vision model.")
                }
            }
            update { $0.kind = ex.kind; $0.text = ex.text; $0.images = images; $0.pages = pages; $0.note = note; $0.state = .ready }
        } catch {
            update { $0.state = .failed(error.localizedDescription) }
        }
        schedulePreview()
    }

    /// Renders PDF pages to JPEGs, yielding between pages so the window stays responsive.
    private static func renderPages(_ doc: PDFDocument, max: Int, maxDimension: CGFloat = 1400) async -> [String] {
        var out: [String] = []
        for i in 0..<min(doc.pageCount, max) {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale = maxDimension / Swift.max(box.width, box.height, 1)
            let img = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
            if let tiff = img.tiffRepresentation, let b64 = ImageProcessor.jpegBase64(from: tiff, maxDimension: Int(maxDimension)) { out.append(b64) }
            await Task.yield()
        }
        return out
    }

    // MARK: running

    func start() {
        guard let boss = bossRef, let c = app?.bridge, !isRunning else { return }
        reset(keepSetup: true)
        phase = .running
        let inputs = files.filter { $0.state == .ready }.map {
            CrewRequest.Input(name: $0.name, kind: $0.kind, text: $0.text, imagesB64: $0.images, workerModel: $0.workerModel, note: $0.note)
        }
        let req = CrewRequest(task: task, boss: boss, workerModel: workerRef, inputs: inputs, preference: preference.rawValue, maxWorkers: maxWorkers, review: review)
        let bossAgent = CrewAgent(id: "boss", title: "Boss", model: boss, isBoss: true, browser: nil)
        agents = [bossAgent]
        runTask = Task { [weak self] in
            do {
                for try await ev in try await c.crewStream(req) { self?.handle(ev) }
            } catch {
                self?.error = error.localizedDescription
            }
            self?.finishRun()
        }
    }

    func cancel() {
        runTask?.cancel()
        if let id = crewID, let c = app?.bridge { Task { try? await c.crewCancel(crew: id) } }
        add("stop.circle", "You stopped the crew.", who: "you")
    }

    private func finishRun() {
        phase = .finished
        for t in browseTasks { t.cancel() }
        needsUser.removeAll()
        for a in agents where a.state == "working" || a.state == "queued" || a.state == "waiting_user" { a.state = "idle" }
    }

    func reset(keepSetup: Bool) {
        runTask?.cancel(); crewID = nil
        for a in agents { a.pushTask?.cancel(); a.browser?.tabs.forEach { a.browser?.closeTab($0.id, persistNow: false) } }
        for a in agents { a.chatTask?.cancel() }
        agents = []; memory = nil; plan = nil; conventions = []; timeline = []; needsUser = []; finalText = ""; contextText = ""; error = nil; focusedID = nil
        panels = []; edges = []; blackboard = nil; nodeOffsets = [:]; dragBase = [:]
        phase = .idle
        if !keepSetup { task = ""; files = [] }
    }

    private func add(_ icon: String, _ text: String, who: String) {
        let item = TimelineItem(icon: icon, text: text, who: who)
        timeline.append(item)
        if timeline.count > 300 { timeline.removeFirst(timeline.count - 300) }
        if let a = agent(who) { a.log.append(item); if a.log.count > 200 { a.log.removeFirst(a.log.count - 200) } }
    }
    private func agent(_ id: String) -> CrewAgent? { agents.first { $0.id == id } }
    private func name(_ id: String) -> String { id == "boss" ? "Boss" : (agent(id)?.title ?? id) }

    // MARK: events

    private func handle(_ ev: CrewEvent) {
        if let id = ev.crewId { crewID = id }
        if let s = ev.start { plan = s.plan; add("memorychip", s.plan.label.isEmpty ? s.plan.reason : s.plan.label, who: "system") }
        if let p = ev.plan { buildWorkers(p) }
        if let s = ev.agentState, let a = agent(s.id) {
            a.state = s.state; if let m = s.model { a.model = m }; a.detail = s.detail ?? ""
        }
        if let id = ev.agent, let inner = ev.ev, let a = agent(id) {
            if a.state != "working" { a.state = "working" }
            let outcome = ChatReducer.apply(inner, to: &a.message)
            if case .approvalNeeded = outcome { Task { await app?.refreshApprovals() } }       // a worker is waiting for your OK (for example to run a command)
        }
        if let p = ev.agentProgress, let a = agent(p.id) { a.progressDone = p.done; a.progressTotal = p.total }
        if let b = ev.blackboard { blackboard = b }
        if let r = ev.review {
            let sentBack = r.verdicts.filter { !$0.ok }.count
            add("checkmark.seal", "The boss reviewed the reports: \(sentBack == 0 ? "all fine" : "\(sentBack) sent back for more work")" + (r.followups > 0 ? ", \(r.followups) new worker(s) added" : "") + ".", who: "boss")
            for v in r.verdicts where !v.ok { add("arrow.uturn.backward", "Boss to \(name(v.id)): \(v.feedback)", who: v.id) }
        }
        if let d = ev.inboxDelivered { add("envelope.open", "\(name(d.agent)) read your message.", who: d.agent) }
        if let sp = ev.spawned { addSpawned(sp) }
        if let m = ev.memory { memory = m; markAwake(m) }
        if let m = ev.modelEvent {
            for a in agents where a.model == m.ref { a.loading = (m.state == "loading"); if m.state == "sleeping" { a.awake = false }; if m.state == "awake" { a.awake = true } }
            if m.state == "sleeping" { add("moon.zzz", "\(crewModelName(m.ref)) went to sleep to free memory.", who: "system") }
            if m.state == "awake" { add("sun.max", "\(crewModelName(m.ref)) woke up.", who: "system") }
        }
        if let m = ev.modeChanged { add("exclamationmark.triangle", m.why + " Now: " + m.label, who: "system"); plan?.label = m.label; plan?.mode = m.to }
        if let q = ev.question { add("questionmark.bubble", "\(name(q.from)) asks the boss: \(q.text)", who: q.from); pulse(q.from, "boss", .question) }
        if let a = ev.answer { add("text.bubble", "Boss to \(name(a.to)): \(a.text)", who: "boss"); pulse("boss", a.to, .question) }
        if let n = ev.needsUser { needsUser.append(n); add("hand.raised", "\(name(n.from)) needs you: \(n.question)", who: n.from) }
        if let r = ev.result, let a = agent(r.id) {
            a.report = r.summary
            a.state = r.skipped == true ? "skipped" : (r.failed == true ? "failed" : "done")
            if r.failed == true { a.detail = r.error ?? "" }
            add(r.failed == true ? "xmark.octagon" : "checkmark.circle", "\(a.title): " + (r.failed == true ? "failed" : r.skipped == true ? "skipped" : "\(r.revised == true ? "improved report" : "report ready") (\(r.summary.count.formatted()) characters)"), who: r.id)
        }
        if let f = ev.final {
            finalText = f.text; contextText = f.context
            boss?.state = "done"; boss?.report = f.text
        }
        if let s = ev.shared { add("square.and.arrow.up", "\(name(s.agent)) shared \(s.key) = \(s.value)", who: s.agent); pulse(s.agent, "boss", .peer) }
        if let p = ev.peer { add("arrow.left.arrow.right", "\(name(p.from)) asked \(name(p.to)): \(p.text)", who: p.from); pulse(p.from, p.to, .peer) }
        if let p = ev.agentProblem, let a = agent(p.id) { a.problems.append(p.message); add("exclamationmark.circle", "\(a.title) hit a problem (try \(p.attempt)): \(p.message)", who: p.id) }
        if let b = ev.browse { let t = Task { await openBrowse(b) }; browseTasks.append(t) }
        if let n = ev.notice { add("info.circle", n, who: "system") }
        if let e = ev.error { error = e.message }
        if ev.cancelled == true { add("stop.circle", "The crew was stopped.", who: "system") }
    }

    private func markAwake(_ m: CrewMemory) {
        let loaded = Set((m.loaded ?? []).map(\.ref))
        for a in agents { a.awake = loaded.contains(a.model); if a.awake { a.loading = false } }
    }

    private func buildWorkers(_ p: CrewEvent.PlanBody) {
        conventions = p.conventions ?? []
        let bossAgent = boss
        var list: [CrewAgent] = bossAgent.map { [$0] } ?? []
        for s in p.subtasks {
            let b = BrowserModel(isolated: true)
            b.isFeatureEnabled = { [weak self] in self?.app?.settings?.browserEnabled ?? true }
            let a = CrewAgent(id: s.id, title: s.title, model: s.model, isBoss: false, browser: b)
            a.inputs = s.inputs; a.instructions = s.instructions; a.state = "queued"; a.size = s.size ?? "small"
            b.onPageFinished = { [weak self, weak a] _ in if let self, let a { self.pushPage(a) } }
            list.append(a)
        }
        withAnimation(Theme.smooth) { agents = list }
        edges = p.subtasks.map { GraphEdge(id: "delegate-boss>\($0.id)", from: "boss", to: $0.id, kind: .delegate, lastPulse: Date()) }
        if let m = memory { markAwake(m) }
        panels = []
        openPanel("boss", .chat)
        for w in workers.prefix(2) { openPanel(w.id, .chat) }
    }

    /// A worker the boss added after reviewing, or a helper another worker asked for.
    private func addSpawned(_ sp: CrewEvent.Spawned) {
        guard agent(sp.id) == nil else { return }
        let b = BrowserModel(isolated: true)
        b.isFeatureEnabled = { [weak self] in self?.app?.settings?.browserEnabled ?? true }
        let a = CrewAgent(id: sp.id, title: sp.title, model: sp.model, isBoss: false, browser: b)
        a.inputs = sp.inputs; a.instructions = sp.instructions; a.state = "queued"; a.parent = sp.parent; a.size = sp.size ?? "small"
        b.onPageFinished = { [weak self, weak a] _ in if let self, let a { self.pushPage(a) } }
        withAnimation(Theme.smooth) { agents.append(a) }
        edges.append(GraphEdge(id: "spawn-\(sp.parent)>\(sp.id)", from: sp.parent, to: sp.id, kind: sp.parent == "boss" ? .delegate : .spawn, lastPulse: Date()))
        add("person.badge.plus", sp.parent == "boss" ? "The boss added a worker: \(sp.title)." : "\(name(sp.parent)) started a helper: \(sp.title).", who: sp.parent)
        if let m = memory { markAwake(m) }
        if panels.count < Self.maxPanels { openPanel(sp.id, .chat) }
    }

    // MARK: graph and workspace

    func pulse(_ from: String, _ to: String, _ kind: GraphEdge.Kind) {
        let id = "\(kind)-\(from)>\(to)"
        if let i = edges.firstIndex(where: { $0.id == id }) { edges[i].lastPulse = Date() }
        else { edges.append(GraphEdge(id: id, from: from, to: to, kind: kind, lastPulse: Date())) }
    }

    /// Opens an agent as a panel. An agent already open in that kind is just brought into focus; beyond four panels the oldest closes.
    func openPanel(_ agentID: String, _ kind: PanelKind) {
        focusedID = agentID
        if panels.contains(where: { $0.agentID == agentID && $0.kind == kind }) { return }
        if kind == .terminal, let a = agent(agentID) { Task { await loadTerminal(a) } }
        panels.append(WorkspacePanel(agentID: agentID, kind: kind))
        if panels.count > Self.maxPanels { panels.removeFirst(panels.count - Self.maxPanels) }
    }
    func closePanel(_ id: UUID) { panels.removeAll { $0.id == id } }
    func setPanelKind(_ id: UUID, _ kind: PanelKind) {
        guard let i = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[i].kind = kind
        if kind == .terminal, let a = agent(panels[i].agentID) { Task { await loadTerminal(a) } }
    }

    func dragNode(_ id: String, by translation: CGSize) {
        let base = dragBase[id] ?? nodeOffsets[id] ?? .zero
        dragBase[id] = base
        nodeOffsets[id] = CGSize(width: base.width + translation.width, height: base.height + translation.height)
    }
    func endDrag(_ id: String) { dragBase[id] = nil }

    // MARK: talking to an agent

    /// While the agent is working your words are queued for its next step; otherwise this is a follow-up chat (its model is woken if needed).
    func send(to agent: CrewAgent, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let c = app?.bridge, let crew = crewID else { return }
        let working = isRunning && (agent.isBoss || ["queued", "working", "waiting_user"].contains(agent.state))
        agent.chat.append(ChatMessage(role: "user", content: t))
        add("person.crop.circle", "You to \(agent.title): \(t)", who: agent.id)
        let agentID = agent.id
        if working {
            Task { [weak agent] in
                do {
                    try await c.crewAgentMessage(crew: crew, agent: agentID, text: t)
                    agent?.chat.append(ChatMessage(role: "assistant", content: "Sent. \(agent?.title ?? "The agent") will see this at its next step."))
                } catch { agent?.chat.append(ChatMessage(role: "assistant", content: "⚠︎ \(error.localizedDescription)")) }
            }
            return
        }
        guard !agent.chatBusy else { return }
        agent.chatBusy = true
        agent.chat.append(ChatMessage(role: "assistant", content: "", model: agent.model))
        let index = agent.chat.count - 1
        agent.chatTask = Task { [weak self, weak agent] in
            do {
                for try await ev in try await c.crewAgentChatStream(crew: crew, agent: agentID, text: t) {
                    guard let self, let agent, index < agent.chat.count else { break }
                    if let inner = ev.ev {
                        let outcome = ChatReducer.apply(inner, to: &agent.chat[index])
                        if case .approvalNeeded = outcome { await self.app?.refreshApprovals() }
                    }
                    if let e = ev.error { agent.chat[index].content += (agent.chat[index].content.isEmpty ? "" : "\n\n") + "⚠︎ " + e.message }
                }
            } catch {
                if let agent, index < agent.chat.count { agent.chat[index].content += (agent.chat[index].content.isEmpty ? "" : "\n\n") + "⚠︎ " + error.localizedDescription }
            }
            agent?.chatBusy = false
        }
    }

    // MARK: terminals

    func loadTerminal(_ agent: CrewAgent) async {
        guard agent.terminalInfo == nil, let c = app?.bridge, let crew = crewID else { return }
        agent.terminalInfo = try? await c.crewTerminalInfo(crew: crew, agent: agent.id)
    }

    /// Runs a command you typed in this agent's own terminal (same allow-list and sandbox as the agent's; its private workspace).
    func runCommand(_ agent: CrewAgent, _ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !agent.terminalBusy, let c = app?.bridge, let crew = crewID else { return }
        agent.terminal.append(TerminalLine(kind: .command, text: cmd))
        agent.terminalBusy = true
        Task { [weak agent] in
            do {
                let r = try await c.crewAgentShell(crew: crew, agent: agent?.id ?? "", command: cmd)
                if !r.output.isEmpty { agent?.terminal.append(TerminalLine(kind: r.ok ? .output : .error, text: r.output)) }
                else if r.ok { agent?.terminal.append(TerminalLine(kind: .info, text: "(no output)")) }
            } catch { agent?.terminal.append(TerminalLine(kind: .error, text: error.localizedDescription)) }
            agent?.terminalBusy = false
        }
    }

    // MARK: each agent's own browser

    /// The bridge asked an agent to look at a page: open it in THAT agent's browser panel, wait for it, and send back what it shows.
    private func openBrowse(_ b: CrewEvent.Browse) async {
        guard let c = app?.bridge, let crew = crewID, let a = agent(b.agent), let br = a.browser else { return }
        guard let url = URL(string: b.url), ["http", "https"].contains((url.scheme ?? "").lowercased()) else {
            try? await c.crewBrowseResult(crew: crew, id: b.id, page: nil, error: "not a web address"); return
        }
        add("safari", "\(a.title) is opening \(url.host ?? b.url)", who: a.id)
        openPanel(a.id, .browser)                                                // show the agent's browser so you can watch it
        br.open(url, newTab: false)
        let deadline = Date().addingTimeInterval(35)
        try? await Task.sleep(nanoseconds: 600_000_000)
        while Date() < deadline, !Task.isCancelled {
            if let t = br.selected, !t.isLoading, t.url != nil { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        try? await Task.sleep(nanoseconds: 900_000_000)                          // let dynamic pages settle
        let payload = await br.contextForSend()
        try? await c.crewBrowseResult(crew: crew, id: b.id, page: payload, error: payload == nil ? "nothing readable on that page" : nil)
    }

    /// The user opened or navigated a page in an agent's browser: that agent sees it as its page context from its next step.
    private func pushPage(_ a: CrewAgent) {
        guard phase == .running, let br = a.browser, let c = app?.bridge, let crew = crewID else { return }
        a.pushTask?.cancel()
        a.pushTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let page = await br.contextForSend() else { return }
            try? await c.crewPage(crew: crew, agent: a.id, page: page)
        }
    }

    // MARK: handing problems back to the user

    func reply(to item: CrewEvent.NeedsUser, text: String) {
        guard let c = app?.bridge, let crew = crewID else { return }
        needsUser.removeAll { $0.id == item.id }
        add("person.crop.circle", "You: \(text)", who: "you")
        Task { try? await c.crewAnswer(crew: crew, id: item.id, text: text) }
    }

    // MARK: after the run

    /// Opens a normal chat that already contains the crew's final answer and all the workers' reports, so you can keep asking about them.
    func continueInChat() {
        guard let app, !finalText.isEmpty else { return }
        app.newConversation()
        var user = ChatMessage(role: "user", content: "Here is the crew's work on my earlier task: \(task)")
        let text = String(contextText.prefix(600_000))
        user.attachments = [Attachment(name: "Crew reports.md", kind: "text", bytes: text.utf8.count, text: text, note: contextText.count > 600_000 ? "Shortened to fit." : nil, chars: contextText.count)]
        app.current.messages = [user, ChatMessage(role: "assistant", content: finalText, model: bossRef)]
        app.selection = .chat
    }
}
