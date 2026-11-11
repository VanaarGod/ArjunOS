import Foundation

// MARK: - Memory and plan (what the bridge reports about this Mac and how it will schedule models)

public struct CrewPlanInfo: Codable, Sendable, Equatable {
    public var feasible: Bool
    public var mode: String?                   // parallel | boss_plus_one | swap | boss_sleeps
    public var label: String
    public var maxWorkers: Int
    public var budget: Int
    public var bossBytes: Int
    public var workerBytes: Int
    public var reason: String
    public var warnings: [String]
}

public struct CrewLoadedModel: Codable, Sendable, Equatable {
    public var ref: String
    public var bytes: Int
    public var busy: Bool?
}

/// A live memory reading. Also streamed during a run, together with the current mode and which models are awake.
public struct CrewMemory: Codable, Sendable, Equatable {
    public var total: Int
    public var available: Int
    public var budget: Int
    public var headroom: Int
    public var pressure: String                // normal | warn | critical
    public var usedPct: Double
    public var swapUsed: Int?
    public var cpuCount: Int?
    public var onBattery: Bool?
    public var source: String?
    public var mode: String?
    public var modeLabel: String?
    public var maxWorkers: Int?
    public var loaded: [CrewLoadedModel]?
    public var cpuPercent: Double?
    public var cpuName: String?
    public var gpuName: String?
    public var gpuLimit: Int?
    public var unified: Bool?
}

public struct CrewModelRow: Codable, Sendable, Equatable, Identifiable {
    public var ref: String
    public var id: String
    public var sizeBytes: Int?
    public var paramsB: Double?
    public var vision: Bool?
    public var manageable: Bool?
    public var contextLength: Int?
}

public struct SystemResources: Codable, Sendable, Equatable {
    public var total: Int
    public var available: Int
    public var budget: Int
    public var headroom: Int
    public var pressure: String
    public var usedPct: Double
    public var swapUsed: Int?
    public var onBattery: Bool?
    public var cpuPercent: Double?
    public var cpuName: String?
    public var gpuName: String?
    public var gpuLimit: Int?
    public var unified: Bool?
    public var loaded: [CrewLoadedModel]
    public var models: [CrewModelRow]
}

public struct CrewPreview: Codable, Sendable, Equatable {
    public struct Worker: Codable, Sendable, Equatable { public var ref: String; public var id: String; public var vision: Bool?; public var paramsB: Double?; public var sizeBytes: Int? }
    public var plan: CrewPlanInfo
    public var boss: String
    public var workers: [Worker]
}

// MARK: - Request

public struct CrewRequest: Encodable, Sendable {
    public struct Input: Encodable, Sendable {
        public var name: String
        public var kind: String
        public var text: String
        public var imagesB64: [String]
        public var workerModel: String?
        public var note: String?
        public init(name: String, kind: String, text: String, imagesB64: [String] = [], workerModel: String? = nil, note: String? = nil) {
            self.name = name; self.kind = kind; self.text = text; self.imagesB64 = imagesB64; self.workerModel = workerModel; self.note = note
        }
        enum CodingKeys: String, CodingKey { case name, kind, text, imagesB64 = "images_b64", workerModel = "worker_model", note }
    }
    public var task: String
    public var boss: String
    public var workerModel: String?
    public var inputs: [Input]
    public var preference: String              // auto | parallel | boss_and_one | one_at_a_time | boss_sleeps
    public var maxWorkers: Int
    public var uiBrowser: Bool
    public var review: Bool
    public init(task: String, boss: String, workerModel: String? = nil, inputs: [Input] = [], preference: String = "auto", maxWorkers: Int = 4, uiBrowser: Bool = true, review: Bool = true) {
        self.task = task; self.boss = boss; self.workerModel = workerModel; self.inputs = inputs
        self.preference = preference; self.maxWorkers = maxWorkers; self.uiBrowser = uiBrowser; self.review = review
    }
    enum CodingKeys: String, CodingKey { case task, boss, workerModel = "worker_model", inputs, preference, maxWorkers = "max_workers", uiBrowser = "ui_browser", review }
}

// MARK: - Streamed events

/// One line of the crew stream. Exactly one field is set per event (the bridge sends one JSON object per event).
public struct CrewEvent: Codable, Sendable, Equatable {
    public struct Start: Codable, Sendable, Equatable { public var id: String; public var plan: CrewPlanInfo; public var boss: String }
    public struct Subtask: Codable, Sendable, Equatable, Identifiable {
        public var id: String; public var title: String; public var inputs: [String]; public var model: String; public var instructions: String; public var size: String?
    }
    public struct Progress: Codable, Sendable, Equatable { public var id: String; public var done: Int; public var total: Int }
    public struct Spawned: Codable, Sendable, Equatable {
        public var id: String; public var title: String; public var inputs: [String]; public var model: String; public var parent: String; public var instructions: String; public var size: String?
    }
    public struct Review: Codable, Sendable, Equatable {
        public struct Verdict: Codable, Sendable, Equatable { public var id: String; public var ok: Bool; public var feedback: String }
        public var verdicts: [Verdict]; public var followups: Int
    }
    public struct InboxDelivered: Codable, Sendable, Equatable { public var agent: String; public var text: String }
    public struct PlanBody: Codable, Sendable, Equatable { public var subtasks: [Subtask]; public var conventions: [String]? }
    public struct AgentState: Codable, Sendable, Equatable { public var id: String; public var state: String; public var model: String?; public var detail: String? }
    public struct ModelEvent: Codable, Sendable, Equatable { public var ref: String; public var state: String }      // loading | awake | sleeping
    public struct ModeChange: Codable, Sendable, Equatable { public var from: String; public var to: String; public var why: String; public var label: String }
    public struct Question: Codable, Sendable, Equatable { public var id: String; public var from: String; public var text: String }
    public struct Answer: Codable, Sendable, Equatable { public var id: String; public var to: String; public var text: String }
    public struct NeedsUser: Codable, Sendable, Equatable, Identifiable { public var id: String; public var from: String; public var kind: String; public var question: String }
    public struct Result: Codable, Sendable, Equatable {
        public var id: String; public var title: String; public var summary: String
        public var inputs: [String]?; public var skipped: Bool?; public var failed: Bool?; public var error: String?; public var revised: Bool?
    }
    public struct Shared: Codable, Sendable, Equatable { public var agent: String; public var key: String; public var value: String }
    public struct Peer: Codable, Sendable, Equatable { public var from: String; public var to: String; public var text: String }
    public struct Problem: Codable, Sendable, Equatable { public var id: String; public var attempt: Int; public var message: String }
    public struct Browse: Codable, Sendable, Equatable { public var id: String; public var agent: String; public var url: String }
    public struct ReportRef: Codable, Sendable, Equatable { public var id: String; public var title: String; public var status: String; public var chars: Int }
    public struct Final: Codable, Sendable, Equatable { public var text: String; public var context: String; public var reports: [ReportRef] }

    public var crewId: String?
    public var start: Start?
    public var plan: PlanBody?
    public var agentState: AgentState?
    public var agent: String?                  // with `ev`: an ordinary chat event (text, tool chips, ...) from that worker
    public var ev: ChatEvent?
    public var memory: CrewMemory?
    public var modelEvent: ModelEvent?
    public var modeChanged: ModeChange?
    public var question: Question?
    public var answer: Answer?
    public var needsUser: NeedsUser?
    public var result: Result?
    public var `final`: Final?
    public var shared: Shared?
    public var peer: Peer?
    public var agentProblem: Problem?
    public var browse: Browse?
    public var notice: String?
    public var error: APIErrorPayload?
    public var done: Bool?
    public var cancelled: Bool?
    public var ping: Bool?
    public var agentProgress: Progress?
    public var spawned: Spawned?
    public var review: Review?
    public var blackboard: CrewBlackboard?
    public var inboxDelivered: InboxDelivered?
}

/// What the whole team shares: rules and terms set by the boss, and facts any worker posted.
public struct CrewBlackboard: Codable, Sendable, Equatable {
    public struct Term: Codable, Sendable, Equatable { public var term: String; public var meaning: String }
    public struct Fact: Codable, Sendable, Equatable { public var key: String; public var value: String; public var agent: String }
    public var conventions: [String]
    public var glossary: [Term]
    public var facts: [Fact]
}

public struct CrewTerminalInfo: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var workspace: String?
    public var allowed: [String]?
    public var javascriptReady: Bool?
    public var sandbox: String?
}

public struct CrewShellResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var blocked: Bool
    public var exitCode: Int?
    public var timedOut: Bool?
    public var output: String
}

public enum CrewMode: String, Sendable {
    case parallel, bossPlusOne = "boss_plus_one", swap, bossSleeps = "boss_sleeps"
    public var title: String {
        switch self { case .parallel: "Everyone awake"; case .bossPlusOne: "Boss + one worker"; case .swap: "One at a time"; case .bossSleeps: "Boss asleep, workers together" }
    }
}

public enum CrewPreference: String, CaseIterable, Identifiable, Sendable {
    case auto, parallel, bossAndOne = "boss_and_one", oneAtATime = "one_at_a_time", bossSleeps = "boss_sleeps"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: "Automatic (best that fits my RAM)"
        case .parallel: "Boss and several workers at once"
        case .bossAndOne: "Boss awake + one worker at a time"
        case .oneAtATime: "One model at a time (boss sleeps)"
        case .bossSleeps: "Boss sleeps, several workers at once"
        }
    }
    /// One line under each choice in the dropdown.
    public var summary: String {
        switch self {
        case .auto: "Uses the most capable arrangement that fits the free memory."
        case .parallel: "The boss and several workers stay loaded together. Needs the most memory."
        case .bossAndOne: "The boss stays loaded; workers go one after another."
        case .oneAtATime: "Only one model is loaded at a time. Slowest, least memory."
        case .bossSleeps: "The boss unloads while workers run in parallel, then wakes to answer questions and write the final answer. Fast on a tight Mac."
        }
    }
}

/// Memory sizes in plain words, e.g. "9.6 GB".
public func crewBytes(_ n: Int) -> String {
    let gb = Double(n) / 1_073_741_824
    return gb >= 10 ? String(format: "%.0f GB", gb) : (gb >= 0.1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(n) / 1_048_576))
}

/// "endpoint|model" -> "model" (shortened for display).
public func crewModelName(_ ref: String) -> String { ref.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ref }

// MARK: - Client

extension BridgeClient {
    public func systemResources() async throws -> SystemResources { try await get("/v1/system/resources") }
    public func crewPreview(_ r: CrewRequest) async throws -> CrewPreview { try await send("POST", "/v1/crew/preview", body: r) }

    struct AnswerBody: Encodable { var id: String; var text: String }
    struct PageBody: Encodable { var agent: String; var page: PagePayload }
    struct BrowseResultBody: Encodable { var id: String; var ok: Bool; var page: PagePayload?; var error: String? }

    public func crewAnswer(crew: String, id: String, text: String) async throws {
        let _: Ack = try await send("POST", "/v1/crew/\(crew)/answer", body: AnswerBody(id: id, text: text))
    }
    public func crewPage(crew: String, agent: String, page: PagePayload) async throws {
        let _: Ack = try await send("POST", "/v1/crew/\(crew)/page", body: PageBody(agent: agent, page: page))
    }
    public func crewBrowseResult(crew: String, id: String, page: PagePayload?, error: String? = nil) async throws {
        let _: Ack = try await send("POST", "/v1/crew/\(crew)/browse_result", body: BrowseResultBody(id: id, ok: page != nil, page: page, error: error))
    }
    public func crewCancel(crew: String) async throws { let _: Ack = try await send("POST", "/v1/crew/\(crew)/cancel") }

    /// Streams crew events. Cancelling the consuming Task cancels the HTTP request, which makes the bridge stop the crew.
    public func crewStream(_ r: CrewRequest) throws -> AsyncThrowingStream<CrewEvent, Error> {
        eventStream(makeRequest("/v1/crew/run", method: "POST", body: try encoder.encode(r), timeout: 3600))
    }

    struct MessageBody: Encodable { var text: String }
    struct ShellBody: Encodable { var command: String }

    /// Say something to an agent that is working right now; it sees it at its next step.
    public func crewAgentMessage(crew: String, agent: String, text: String) async throws {
        let _: Ack = try await send("POST", "/v1/crew/\(crew)/agents/\(agent)/message", body: MessageBody(text: text))
    }

    /// A follow-up chat with one agent (wakes its model if needed). Streams the same event shapes as the crew itself.
    public func crewAgentChatStream(crew: String, agent: String, text: String) throws -> AsyncThrowingStream<CrewEvent, Error> {
        eventStream(makeRequest("/v1/crew/\(crew)/agents/\(agent)/chat", method: "POST", body: try encoder.encode(MessageBody(text: text)), timeout: 1800))
    }

    public func crewTerminalInfo(crew: String, agent: String) async throws -> CrewTerminalInfo { try await get("/v1/crew/\(crew)/agents/\(agent)/terminal") }

    /// A command you type in an agent's terminal: same allow-list and sandbox as the agent's own, in that agent's private workspace.
    public func crewAgentShell(crew: String, agent: String, command: String) async throws -> CrewShellResult {
        try await send("POST", "/v1/crew/\(crew)/agents/\(agent)/shell", body: ShellBody(command: command))
    }

    private func eventStream(_ req: URLRequest) -> AsyncThrowingStream<CrewEvent, Error> {
        let session = self.session, decoder = self.decoder
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw BridgeError.transport("non-HTTP response") }
                    guard (200..<300).contains(http.statusCode) else {
                        var raw = ""
                        for try await line in bytes.lines { raw += line }
                        let msg = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                            .flatMap { ($0["detail"] ?? $0["error"]) as? String } ?? "request failed"
                        throw BridgeError.http(status: http.statusCode, message: msg)
                    }
                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(line), let data = payload.data(using: .utf8) else { continue }
                        do { continuation.yield(try decoder.decode(CrewEvent.self, from: data)) }
                        catch { throw BridgeError.decoding(String(describing: error)) }
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
