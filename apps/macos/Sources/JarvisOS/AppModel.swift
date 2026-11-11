import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers
import JarvisCore

struct DraftAttachment: Identifiable, Equatable {
    enum State: Equatable { case reading, ready, failed(String) }
    let id = UUID()
    var name: String
    var bytes: Int
    var state: State
    var attachment: Attachment?
}

enum NavSection: String, CaseIterable, Identifiable {
    case chat = "New chat", crew = "Crew", models = "Models", tools = "MCP Servers", memory = "Memory"
    case voice = "Voice", knowledge = "Knowledge", tasks = "Tasks", system = "System", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .chat: "square.and.pencil"; case .crew: "person.3.sequence"; case .models: "cpu"; case .tools: "square.grid.2x2"
        case .memory: "brain"; case .voice: "waveform"; case .knowledge: "books.vertical"; case .tasks: "checklist"
        case .system: "gauge.with.dots.needle.33percent"; case .settings: "gearshape"
        }
    }
}

/// What the menu bar icon shows. Priority order is the order of the checks in `AppModel.menuState`.
enum MenuState: Equatable {
    case asleep          // no window is open: the app is resting in the menu bar
    case idle            // window open, nothing happening
    case thinking        // working on an answer
    case needsApproval   // waiting for you to approve a command or tool
    case done            // finished while you were away (green until you look, then it clears)
    case error           // the bridge is down

    var label: String {
        switch self {
        case .asleep: "Asleep"; case .idle: "Ready"; case .thinking: "Thinking…"
        case .needsApproval: "Waiting for your approval"; case .done: "Done"; case .error: "Needs attention"
        }
    }
}

@MainActor @Observable
final class AppModel {
    // Settings (non-secret)
    var assistantName: String
    var offlineMode: Bool
    var pythonPath: String

    // Navigation
    var selection: NavSection = .chat
    var settingsSection: SettingsSection = .general       // which Settings page is showing (also used to deep-link into one)
    var searchText = "" { didSet { scheduleContentSearch() } }
    private(set) var contentMatches: Set<UUID> = []          // chats whose TEXT matches the search box (found off the main thread)
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // Live state (all from the bridge; nothing fabricated)
    var bridgeState: BridgeState = .stopped
    var providers: [Provider] = []
    var models: [ModelEntry] = []
    var approvals: [Approval] = []
    var memoryHits: [MemoryHit] = []
    private(set) var memoryItems: [MemoryRecord] = []         // everything saved, newest first: the Memory screen shows this without a search
    private(set) var memoriesLoaded = false
    var profile: UserProfile?                                  // who the user is (Settings → Profile); nil until the bridge answers
    /// True until the user has answered (or skipped) the first-launch "what should I call you?" question.
    var needsWelcome: Bool { profile.map { !$0.onboarded } ?? false }
    /// How the user is named in the app: what they asked to be called, else their full name, else just "You". Never read from macOS.
    var userLabel: String {
        let p = profile
        for s in [p?.callMe, p?.name] { if let s, !s.isEmpty { return s } }
        return "You"
    }
    var lastError: String?
    var scanLog: [String] = []
    var mcpServers: [MCPServer] = []
    var mcpDirectory: String?
    var settings: AppSettings?
    var health: BridgeHealth?
    var searchConsentDismissed = false
    var didFirstScan = false

    // Terminal (sandbox) state
    var shellStatus: ShellStatus?
    var sandboxTest: SandboxSelfTest?
    var sandboxTesting = false

    // Floating assistant (pet + mini chat): another view of this same model
    let floating = FloatingAssistantController()

    // Integrated browser
    let browser = BrowserModel()
    var pageReading = false
    var openLinksInBrowser = true
    func setOpenLinksInBrowser(_ on: Bool) { openLinksInBrowser = on; UserDefaults.standard.set(on, forKey: "openLinksInBrowser") }

    // Stall protection
    var modelThinking = false                 // the model is reasoning: show "Thinking…" instead of looking frozen
    private var lastEventAt = Date()
    private var watchdogTask: Task<Void, Never>?
    static let stallSeconds: TimeInterval = 90        // the bridge sends a heartbeat every 5 s, so 90 s of nothing means it is stuck

    // Menu bar / window state
    var windowVisible = true
    var windowOccluded = false            // fully covered by other windows: nothing needs to animate or poll quickly
    var windowIdle: Bool { !windowVisible || windowOccluded }
    var doneUnread = false
    var menuFrame = 0
    private var doneClearTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?

    // Chat
    var conversations: [Conversation] = []
    var current: Conversation = Conversation() {
        didSet {                                          // the sidebar watches these two, NOT `current`, so a streaming reply does not redraw it
            if current.id != currentID { currentID = current.id }
            let empty = current.messages.isEmpty
            if empty != currentIsEmpty { currentIsEmpty = empty }
        }
    }
    private(set) var currentID = UUID()
    private(set) var currentIsEmpty = true
    @ObservationIgnored private var pendingSelectID: UUID?
    @ObservationIgnored private var streamWorking = Conversation()    // the reply being built; the UI copy is refreshed at most ~14 times a second
    @ObservationIgnored private var streamDirty = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    private(set) var selectedModelKey: String?
    var isStreaming = false
    var streamError: String?
    private var streamTask: Task<Void, Never>?

    // Attachments being prepared for the next message
    var drafts: [DraftAttachment] = []
    static let maxFileBytes = 25 * 1024 * 1024
    static let maxAttachments = 8

    let supervisor = BridgeSupervisor()
    let store: ConversationStore?
    private var client: BridgeClient?
    var bridge: BridgeClient? { client }              // for the crew and other features that talk to the bridge directly
    let crew = CrewModel()
    let vault = VaultModel()
    private var pollTask: Task<Void, Never>?
    private var lastSignature = ""

    init() {
        let d = UserDefaults.standard
        openLinksInBrowser = d.object(forKey: "openLinksInBrowser") as? Bool ?? true
        let stored = d.string(forKey: "assistantName")
        assistantName = (stored == nil || stored == "JARVIS" || stored == "JARVIS OS" || stored?.trimmingCharacters(in: .whitespaces).isEmpty == true) ? "ArjunOS" : (stored ?? "ArjunOS")
        offlineMode = d.bool(forKey: "offlineMode")
        pythonPath = d.string(forKey: "pythonPath") ?? Self.supportDir.appendingPathComponent("venv/bin/python3").path
        store = try? ConversationStore(directory: Self.supportDir.appendingPathComponent("conversations"))
        currentID = current.id
        browser.isFeatureEnabled = { [weak self] in self?.settings?.browserEnabled ?? true }
        browser.onOpened = { AppWindows.ensureWidth(1480) }
        LinkRouter.handler = { [weak self] url in self?.openLink(url) }
        if let store {                                    // chat list: headers only, read off the main thread
            Task { [weak self] in
                let list = await Task.detached(priority: .userInitiated) { store.loadSummaries() }.value
                self?.mergeLoaded(list)
            }
        }
    }

    private func mergeLoaded(_ list: [Conversation]) {
        let known = Set(conversations.map(\.id))
        conversations += list.filter { !known.contains($0.id) }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Links in chat answers and source chips open in the built-in browser (when it is on); everything else goes to the system.
    func openLink(_ url: URL) {
        let scheme = (url.scheme ?? "").lowercased()
        if (scheme == "http" || scheme == "https") && openLinksInBrowser { browser.open(url) } else { NSWorkspace.shared.open(url) }
    }

    /// Explicit persistence (no reliance on property observers inside @Observable).
    func saveSettings() {
        let d = UserDefaults.standard
        d.set(assistantName, forKey: "assistantName"); d.set(offlineMode, forKey: "offlineMode"); d.set(pythonPath, forKey: "pythonPath")
    }
    func selectModel(_ key: String?) {
        selectedModelKey = key
        if let key { UserDefaults.standard.set(key, forKey: "lastModelKey") }
    }

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JarvisOS")
    }
    /// Present only when running from the packaged .app (scripts/package.sh copies the bridge here).
    static var bundledBridgePath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("bridge").path
    }

    // MARK: Menu bar state
    var menuState: MenuState {
        if case .failed = bridgeState { return .error }
        if !approvals.isEmpty { return .needsApproval }
        if isStreaming { return .thinking }
        if doneUnread { return .done }
        return windowVisible ? .idle : .asleep
    }

    /// The user has seen the finished answer (for example by opening the mini chat): clear the green tick now.
    func clearDone() { doneUnread = false; doneClearTask?.cancel() }

    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        if visible && doneUnread { scheduleDoneClear(after: 4) }     // let the green tick be seen once, then clear it
        if visible { refreshSoon() }
    }
    func setWindowOccluded(_ occluded: Bool) {
        guard windowOccluded != occluded else { return }
        windowOccluded = occluded
        if !occluded { refreshSoon() }                                // coming back into view: catch up once, now
    }
    private func refreshSoon() {
        guard client != nil else { return }
        Task { [weak self] in await self?.rescan(force: false); await self?.refreshApprovals() }
    }

    private func scheduleDoneClear(after seconds: Double) {
        doneClearTask?.cancel()
        doneClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.doneUnread = false
        }
    }

    private func startThinkingTicker() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self else { return }
                self.menuFrame = (self.menuFrame + 1) % 3
            }
        }
    }
    /// If nothing at all arrives for `stallSeconds` (not even heartbeats) the stream is stuck: stop it and say so, instead of spinning forever.
    private func startWatchdog() {
        watchdogTask?.cancel()
        lastEventAt = Date()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.isStreaming else { return }
                if Date().timeIntervalSince(self.lastEventAt) > Self.stallSeconds {
                    self.streamError = "No response for \(Int(Self.stallSeconds)) seconds, so I stopped it. The model or the bridge may be stuck. Try again, or restart the bridge in Settings."
                    self.streamTask?.cancel()
                    return
                }
            }
        }
    }

    private func stopThinkingTicker() { frameTask?.cancel(); frameTask = nil; menuFrame = 0 }

    // MARK: Derived
    /// Show the one-time web-search permission prompt (the app only ever sends the short search QUERY, never the chat).
    var needsSearchConsent: Bool {
        guard let st = settings else { return false }
        return !st.webSearchConsented && !searchConsentDismissed && !offlineMode
    }
    var ollama: Provider? { providers.first { $0.kind == "ollama" && $0.isUsable } }
    var chatModels: [ModelEntry] { models.filter { $0.modelID != nil && !Self.looksLikeEmbedding($0.modelID ?? "") } }
    /// A readable version of a model id for tight spaces: drops the `hf.co/org/` prefix, and for GGUF repos shows the file name
    /// instead of "Repo-GGUF:file.gguf". The full id stays available via `.help`.
    static func shortModelName(_ id: String) -> String {
        var name = id.split(separator: "/").last.map(String.init) ?? id
        if let colon = name.firstIndex(of: ":") {
            let head = String(name[..<colon]), tag = String(name[name.index(after: colon)...])
            if head.lowercased().hasSuffix("-gguf") || tag.lowercased().hasSuffix(".gguf") { name = tag }
        }
        if name.lowercased().hasSuffix(".gguf") { name = String(name.dropLast(5)) }
        return name.isEmpty ? id : name
    }
    var selectedModelShortName: String? { selectedModelName.map(Self.shortModelName) }
    var selectedModelName: String? { selectedModelKey?.split(separator: "|", maxSplits: 1).last.map(String.init) }

    /// A plain-language explanation of why chat can't be used yet (nil when it can).
    var connectionHint: String? {
        switch bridgeState {
        case .starting, .stopped: return "Starting the local bridge…"
        case .failed: return "The local bridge isn't running. See the banner above."
        case .running: break
        }
        guard didFirstScan else { return "Looking for Ollama…" }
        if !chatModels.isEmpty { return nil }
        if ollama == nil { return "Ollama isn't running. Start it and \(assistantName) will connect automatically." }
        return "Ollama is running but has no chat models. Install one, e.g. `ollama pull llama3.2:3b`."
    }

    static func looksLikeEmbedding(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["embed", "bge-", "nomic", "minilm", "e5-"].contains { n.contains($0) }
    }

    // MARK: Bridge lifecycle
    func bootstrap() async {
        crew.attach(self)
        vault.attach(self)
        await supervisor.start(BridgeLaunchConfig(pythonExecutable: pythonPath,
                                                  stateDirectory: Self.supportDir.appendingPathComponent("state"),
                                                  offline: offlineMode, bundledBridgePath: Self.bundledBridgePath))
        bridgeState = await supervisor.state; client = await supervisor.client
        guard client != nil else { return }
        await rescan(force: true); await refreshAll(); await refreshSettings(); await refreshProfile(); await refreshMemories(); await refreshMCP(); await refreshHealth(); await refreshShell()
        pollTask?.cancel()
        pollTask = Task { [weak self] in                      // auto-connect: keep discovering Ollama + new models, calmly
            var lastScan = Date()
            while !Task.isCancelled {
                let tick = self?.pollTick ?? 15
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(lastScan) >= self.scanInterval - 0.5 { lastScan = Date(); await self.rescan(force: false) }
                await self.refreshApprovals()
                if self.selection == .tools && !self.windowIdle { await self.refreshMCP() }
            }
        }
    }
    /// How often to look for engines. Quick while nothing is connected (so Ollama is found as soon as it starts), relaxed once a model
    /// is available, and slower still when the window is hidden or covered. Opening the window triggers an immediate catch-up scan.
    private var scanInterval: TimeInterval { chatModels.isEmpty ? (windowIdle ? 20 : 6) : (windowIdle ? 60 : 20) }
    private var pollTick: TimeInterval { windowIdle ? 15 : 6 }          // approvals are checked every tick; they are tiny requests

    func restartBridge() async { pollTask?.cancel(); await supervisor.stop(); await bootstrap() }
    func shutdown() async { streamTask?.cancel(); pollTask?.cancel(); await supervisor.stop() }

    private func run<T>(_ label: String, quiet: Bool = false, _ op: (BridgeClient) async throws -> T) async -> T? {
        guard let c = client else { if !quiet { lastError = "The local bridge is not running. Open Settings → Diagnostics to restart it." }; return nil }
        do { if !quiet { lastError = nil }; return try await op(c) }
        catch { if !quiet { lastError = "\(label): \(error.localizedDescription)" }; return nil }
    }

    func refreshAll() async {
        await refreshApprovals()
    }
    func refreshApprovals() async { if let a = await run("Approvals", quiet: true, { try await $0.approvals() }) { approvals = a } }

    /// Probe loopback engines. Models are re-listed only when something actually changed.
    func rescan(force: Bool) async {
        if let r = await run("Scan", quiet: !force, { try await $0.scan() }) { scanLog = r.logTail }
        guard let p = await run("Providers", quiet: !force, { try await $0.providers() }) else { return }
        providers = p; didFirstScan = true
        let sig = p.map { "\($0.key):\($0.status):\($0.models.joined(separator: ","))" }.joined(separator: ";")
        if force || sig != lastSignature || models.isEmpty {
            lastSignature = sig
            if let m = await run("Models", quiet: !force, { try await $0.models() }) { models = m }
        }
        reconcileSelectedModel()
    }
    func rescan() async { await rescan(force: true) }

    /// Default model: keep the current one if still installed, else the last-used one, else the first Ollama chat model.
    private func reconcileSelectedModel() {
        let valid = Set(chatModels.compactMap { m in m.modelID.map { "\(m.endpoint)|\($0)" } })
        if let k = selectedModelKey, valid.contains(k) { return }
        if let saved = UserDefaults.standard.string(forKey: "lastModelKey"), valid.contains(saved) { selectModel(saved); return }
        let ollamaKeys = Set(providers.filter { $0.kind == "ollama" && $0.isUsable }.map(\.key))
        let pick = chatModels.first { ollamaKeys.contains($0.endpoint) } ?? chatModels.first
        selectModel(pick.flatMap { m in m.modelID.map { "\(m.endpoint)|\($0)" } })
    }

    func addEndpoint(_ url: String) async { _ = await run("Add endpoint", { try await $0.addEndpoint(url: url) }); await rescan(force: true) }

    // MARK: Attachments
    var isReadingFiles: Bool { drafts.contains { $0.state == .reading } }
    var readyAttachments: [Attachment] { drafts.compactMap { $0.state == .ready ? $0.attachment : nil } }

    func addFiles(_ urls: [URL]) {
        for url in urls { Task { await addFile(url) } }
    }

    func removeDraft(_ id: UUID) { drafts.removeAll { $0.id == id } }

    private func updateDraft(_ id: UUID, _ change: (inout DraftAttachment) -> Void) {
        if let i = drafts.firstIndex(where: { $0.id == id }) { change(&drafts[i]) }
    }

    private func addFile(_ url: URL) async {
        let name = url.lastPathComponent
        guard drafts.count < Self.maxAttachments else { streamError = "You can attach up to \(Self.maxAttachments) files to one message."; return }
        let draft = DraftAttachment(name: name, bytes: 0, state: .reading)
        drafts.append(draft)
        let id = draft.id
        let limit = Self.maxFileBytes

        enum ReadResult { case ok(Data), failed(String) }
        let read: ReadResult = await Task<ReadResult, Never>.detached(priority: .userInitiated) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { return .failed("Folders can't be attached. Attach the files inside instead.") }
            if let size = values?.fileSize, size > limit { return .failed("Larger than the \(limit / 1_048_576) MB limit.") }
            do { return .ok(try Data(contentsOf: url, options: .mappedIfSafe)) }
            catch { return .failed("Couldn't read the file (\(error.localizedDescription)).") }
        }.value

        guard case .ok(let data) = read else {
            if case .failed(let m) = read { updateDraft(id) { $0.state = .failed(m) } }
            return
        }
        updateDraft(id) { $0.bytes = data.count }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true

        if isImage {
            let b64: String? = await Task<String?, Never>.detached(priority: .userInitiated) { ImageProcessor.jpegBase64(from: data) }.value
            guard let b64 else { updateDraft(id) { $0.state = .failed("This image couldn't be read.") }; return }
            let a = Attachment(name: name, kind: "image", bytes: data.count, imageBase64: b64)
            updateDraft(id) { $0.attachment = a; $0.state = .ready }
            return
        }
        guard let client else { updateDraft(id) { $0.state = .failed("The local bridge isn't running.") }; return }
        do {
            let ex = try await client.extractFile(name: name, data: data)
            if ex.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateDraft(id) { $0.state = .failed(ex.warning ?? "No text was found in this file.") }; return
            }
            let a = Attachment(name: name, kind: ex.kind, bytes: data.count, text: ex.text, note: ex.warning, chars: ex.chars)
            updateDraft(id) { $0.attachment = a; $0.state = .ready }
        } catch let BridgeError.http(_, message) {
            updateDraft(id) { $0.state = .failed(message) }
        } catch {
            updateDraft(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    // MARK: Chat
    func newConversation(temporary: Bool = false) {
        pendingSelectID = nil
        current = Conversation(title: "New conversation", temporary: temporary); streamError = nil; drafts.removeAll(); selection = .chat
    }
    /// Opens a chat from the sidebar. The list only holds headers, so the messages are read from disk (off the main thread).
    func select(_ c: Conversation) {
        streamError = nil; selection = .chat
        pendingSelectID = c.id
        if c.id == current.id { return }
        if isStreaming && c.id == streamWorking.id { current = streamWorking; return }
        if !c.messages.isEmpty { current = c; return }
        guard let store else { current = c; return }
        let id = c.id
        Task { [weak self] in
            let full = await Task.detached(priority: .userInitiated) { store.load(id) }.value
            guard let self, self.pendingSelectID == id else { return }          // the user already clicked something else
            self.current = full ?? c
        }
    }
    /// The whole conversation (with messages) for export and similar, whether or not it is the one on screen.
    func fullConversation(_ c: Conversation) -> Conversation {
        if c.id == current.id { return current }
        return store?.load(c.id) ?? c
    }
    func deleteConversation(_ c: Conversation) {
        try? store?.delete(c.id); conversations.removeAll { $0.id == c.id }
        if current.id == c.id { newConversation() }
    }
    var filteredConversations: [Conversation] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return conversations }
        return conversations.filter { $0.title.lowercased().contains(q) || contentMatches.contains($0.id) }
    }

    /// Titles match instantly; message text is searched in the background (debounced) so typing never stalls the window.
    private func scheduleContentSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let store else { if !contentMatches.isEmpty { contentMatches = [] }; return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let ids = await Task.detached(priority: .utility) { store.searchIDs(q) }.value
            if Task.isCancelled { return }
            self?.contentMatches = ids
        }
    }

    func send(_ text: String, extraAttachments: [Attachment] = []) {
        guard !isStreaming else { return }
        guard let key = selectedModelKey, let client else {
            streamError = connectionHint ?? "Select a model first."; return
        }
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init); guard parts.count == 2 else { return }
        guard !isReadingFiles else { streamError = "Still reading your attachments — one moment."; return }
        streamError = nil
        doneUnread = false; doneClearTask?.cancel()
        var userMessage = ChatMessage(role: "user", content: text)
        let attached = readyAttachments + extraAttachments
        if !attached.isEmpty { userMessage.attachments = attached }
        drafts.removeAll()
        current.messages.append(userMessage)
        if current.messages.count == 1 { current.title = String(text.prefix(48)) }
        current.endpoint = parts[0]; current.model = parts[1]
        let history = current.messages
        current.messages.append(ChatMessage(role: "assistant", content: "", model: parts[1]))
        isStreaming = true
        streamWorking = current; streamDirty = false
        startThinkingTicker(); startWatchdog(); startFlushTicker(); modelThinking = false
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                var page: PagePayload? = nil
                if self.browser.wantsContext {                                  // read the live page now, so the answer reflects what is open at this moment
                    self.pageReading = true
                    page = await self.browser.contextForSend()
                    self.pageReading = false
                    self.lastEventAt = Date()
                }
                let stream = try await client.chatStream(endpoint: parts[0], model: parts[1], messages: history, page: page)
                for try await ev in stream {
                    self.lastEventAt = Date()
                    let last = self.streamWorking.messages.count - 1
                    let outcome = ChatReducer.apply(ev, to: &self.streamWorking.messages[last])       // in place: no copy of the growing text per token
                    if outcome == .thinking { self.modelThinking = true } else if !(ev.ping ?? false) && !(ev.delta ?? "").isEmpty { self.modelThinking = false }
                    if !(ev.ping ?? false) { self.streamDirty = true }
                    switch outcome {
                    case .failed(let m): self.streamError = m
                    case .approvalNeeded: self.flushStream(); await self.refreshApprovals()
                    case .none: break                                           // plain text: the ticker publishes it a few times a second
                    default: self.flushStream()                                 // tool chips, notices, finish: show right away
                    }
                    if case .failed = outcome { break }
                }
            } catch { if self.streamError == nil && !Task.isCancelled { self.streamError = error.localizedDescription } }   // a Stop or watchdog cancel is not a new error
            // no empty bubbles, but keep one that shows what happened (a command or file chip) so a quiet model never erases it
            if let last = self.streamWorking.messages.last, last.content.isEmpty, (last.activity ?? []).isEmpty { self.streamWorking.messages.removeLast() }
            if self.streamError != nil, let last = self.streamWorking.messages.last, last.role == "assistant", last.content.isEmpty, !(last.activity ?? []).isEmpty {
                self.streamWorking.messages[self.streamWorking.messages.count - 1].content = "_This reply stopped early._"
            }
            self.finishStream()
        }
    }

    /// Copies the reply being built into the UI, if the user is still looking at that chat.
    private func flushStream() {
        streamDirty = false
        if current.id == streamWorking.id { current = streamWorking }
    }
    private func startFlushTicker() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 70_000_000)
                guard let self else { return }
                if self.streamDirty { self.flushStream() }
            }
        }
    }
    func stopStreaming() { streamTask?.cancel() }
    private func finishStream() {
        let cleanFinish = streamError == nil && !Task.isCancelled
        flushTask?.cancel(); flushTask = nil
        var done = streamWorking; done.updatedAt = Date()
        streamWorking = Conversation(); streamDirty = false              // let go of the working copy
        if current.id == done.id { current = done }
        isStreaming = false
        stopThinkingTicker(); watchdogTask?.cancel(); watchdogTask = nil; modelThinking = false
        if cleanFinish { doneUnread = true; if windowVisible { scheduleDoneClear(after: 4) } }
        persist(done)
    }

    /// Writes the chat to disk off the main thread (a chat with images can be large) and keeps only its header in the sidebar list.
    private func persist(_ c: Conversation) {
        if !c.temporary, let store { Task.detached(priority: .utility) { try? store.save(c) } }
        var header = c; header.messages = []
        if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i] = header }
        else if !c.temporary { conversations.insert(header, at: 0) }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Memory / approvals / MCP
    func searchMemory(_ q: String) async { if let h = await run("Memory", { try await $0.searchMemory(q) }) { memoryHits = h } }
    /// `confirmed` is only ever true when the USER explicitly ticks "confirm as long-term preference" in the UI.
    func addMemory(_ text: String, category: String, confirmed: Bool) async {
        _ = await run("Memory", { try await $0.addMemory(text, category: category, confirmed: confirmed) }); await refreshMemories()
    }
    func confirm(_ id: String, query: String) async {
        _ = await run("Memory", { try await $0.confirmMemory(id) }); await refreshMemories(); if !query.isEmpty { await searchMemory(query) }
    }
    func deleteMemory(_ id: String, query: String) async {
        _ = await run("Memory", { try await $0.deleteMemory(id) }); await refreshMemories(); if !query.isEmpty { await searchMemory(query) }
    }
    func refreshMemories() async { if let m = await run("Memory", quiet: true, { try await $0.memoryList() }) { memoryItems = m; memoriesLoaded = true } }

    // MARK: Profile
    func refreshProfile() async { if let p = await run("Profile", quiet: true, { try await $0.profile() }) { profile = p } }
    /// Saves profile changes. Returns a message to show the user if the bridge refused them (for example, too long), else nil.
    func saveProfile(_ u: ProfileUpdate) async -> String? {
        guard let c = client else { return "The local bridge is not running. Open Settings → Diagnostics to restart it." }
        do {
            profile = try await c.updateProfile(u)
            if u.callMe != nil || u.name != nil { await refreshMemories() }          // the name is also the first memory
            return nil
        } catch let BridgeError.http(_, message) { return message }
        catch { return error.localizedDescription }
    }
    func previewProfile(_ u: ProfileUpdate) async -> ProfilePreview? {
        guard let c = client else { return nil }
        return try? await c.previewProfile(u)
    }
    func resolve(_ id: String, approve: Bool) async { _ = await run("Approval", { try await $0.resolveApproval(id, approve: approve) }); await refreshApprovals() }

    // MARK: Settings & web search
    func refreshHealth() async { if let h = await run("Health", quiet: true, { try await $0.health() }) { health = h } }
    func openVaultNote(_ path: String) { vault.openInObsidian(path) }
    func refreshSettings() async { if let st = await run("Settings", quiet: true, { try await $0.settings() }) { settings = st } }
    func updateSettings(mode: String? = nil, consent: Bool? = nil, maxResults: Int? = nil, inject: Bool? = nil, attachmentChars: Int? = nil, shell: Bool? = nil, files: Bool? = nil, readPaths: Bool? = nil, browser: Bool? = nil, pageChars: Int? = nil) async {
        if let st = await run("Settings", { try await $0.updateSettings(webSearchMode: mode, webSearchConsented: consent, webSearchMaxResults: maxResults, memoryAutoInject: inject, attachmentContextChars: attachmentChars, shellEnabled: shell, filesEnabled: files, readPaths: readPaths, browserEnabled: browser, pageContextChars: pageChars) }) { settings = st }
        if shell != nil { await refreshShell() }
    }

    // MARK: Created files
    /// Absolute path of a file the assistant created (activities carry it; fall back to workspace + name).
    func fileURL(for a: MessageActivity) -> URL? {
        if let p = a.path { return URL(fileURLWithPath: p) }
        guard let ws = shellStatus?.workspace, let name = a.detail else { return nil }
        return URL(fileURLWithPath: ws).appendingPathComponent(name)
    }
    func revealFile(_ a: MessageActivity) { if let u = fileURL(for: a) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    func openFile(_ a: MessageActivity) { if let u = fileURL(for: a) { NSWorkspace.shared.open(u) } }

    // MARK: Terminal sandbox
    func refreshShell() async { if let st = await run("Terminal", quiet: true, { try await $0.shellStatus() }) { shellStatus = st } }
    func runSandboxSelfTest() async {
        sandboxTesting = true; sandboxTest = nil
        sandboxTest = await run("Sandbox test", { try await $0.shellSelfTest() })
        sandboxTesting = false
    }
    func testWebSearch() async -> Result<[SearchResultItem], Error> {
        guard let c = client else { return .failure(BridgeError.notRunning) }
        do { return .success(try await c.testWebSearch().results) } catch { return .failure(error) }
    }

    // MARK: MCP (one JSON file per server). Methods that feed an editor return an error string instead of a global banner.
    func refreshMCP() async {
        if let s = await run("MCP", quiet: true, { try await $0.mcpServers() }) { mcpServers = s }
        if mcpDirectory == nil { mcpDirectory = await run("MCP", quiet: true, { try await $0.mcpDirectory() }) }
    }
    private func attempt(_ op: (BridgeClient) async throws -> Void) async -> String? {
        guard let c = client else { return BridgeError.notRunning.localizedDescription }
        do { try await op(c); await refreshMCP(); return nil } catch { await refreshMCP(); return error.localizedDescription }
    }
    func saveMCP(name: String, text: String) async -> String? { await attempt { _ = try await $0.saveMCPServer(name: name, text: text) } }
    func importMCP(text: String, name: String?, overwrite: Bool) async -> String? { await attempt { _ = try await $0.importMCP(text: text, name: name, overwrite: overwrite) } }
    func deleteMCP(_ name: String) async -> String? { await attempt { try await $0.deleteMCPServer(name) } }
    func approveAndConnectMCP(_ name: String) async -> String? { await attempt { try await $0.approveMCPServer(name); _ = try await $0.connectMCPServer(name) } }
    func connectMCP(_ name: String) async -> String? { await attempt { _ = try await $0.connectMCPServer(name) } }
    func disconnectMCP(_ name: String) async -> String? { await attempt { try await $0.disconnectMCPServer(name) } }
    func trustMCPTool(server: String, tool: String, trusted: Bool) async -> String? { await attempt { try await $0.trustMCPTool(server: server, tool: tool, trusted: trusted) } }

    /// "Undo" on a saved-memory chip: really deletes the memory and records that in the message.
    func undoMemory(_ memoryID: String) async {
        guard await run("Memory", { try await $0.deleteMemory(memoryID) }) != nil else { return }
        for i in current.messages.indices {
            guard var acts = current.messages[i].activity else { continue }
            for j in acts.indices where acts[j].memoryID == memoryID {
                acts[j].title = "Memory removed"; acts[j].status = "removed"; acts[j].memoryID = nil
            }
            current.messages[i].activity = acts
        }
        try? store?.save(current)
    }
}
