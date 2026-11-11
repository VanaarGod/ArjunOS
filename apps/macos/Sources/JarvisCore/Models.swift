import Foundation

// Wire models for the bridge API v1. The bridge speaks snake_case; BridgeClient converts.
// Optionals are deliberate: "unknown" is never rendered as a fabricated value.

public struct BridgeHealth: Codable, Sendable, Equatable {
    public var ok: Bool
    public var bridgeVersion: String
    public var apiVersion: String
    public var offlineMode: Bool
    public var memorySchema: Int
    public var python: String?           // the interpreter the bridge is running under
    public var pdfSupport: Bool?         // can this bridge read PDFs? (nil = older bridge)
}

public struct Provider: Codable, Sendable, Identifiable, Equatable {
    public var key: String
    public var baseUrl: String
    public var kind: String          // ollama | openjarvis | openai_compat | unknown
    public var status: String        // validated | auth_required | unreachable | unrecognized | rejected
    public var owner: String
    public var hint: String
    public var version: String?
    public var models: [String]
    public var latencyMs: Double?
    public var lastSeen: Double?
    public var lastError: String?
    public var failures: Int
    public var id: String { key }
    public var isUsable: Bool { status == "validated" }
}

public struct Capabilities: Codable, Sendable, Equatable {
    public var chat: Bool?
    public var streaming: Bool?
    public var tools: Bool?
    public var vision: Bool?
    public var embeddings: Bool?
    public var structuredOutput: Bool?
}

public struct APIErrorPayload: Codable, Sendable, Equatable {
    public var kind: String
    public var message: String
    public var status: Int?
}

public struct ModelEntry: Codable, Sendable, Identifiable, Equatable {
    public var endpoint: String
    public var modelID: String?                 // wire key is "id"
    public var sizeBytes: Int?
    public var family: String?
    public var quantization: String?
    public var contextLength: Int?
    public var capabilities: Capabilities?
    public var local: Bool?
    public var error: APIErrorPayload?          // present instead of a model when an endpoint failed to list
    /// Composite identity: the same model name on two endpoints must stay distinct.
    public var id: String { "\(endpoint)|\(modelID ?? "error")" }
    enum CodingKeys: String, CodingKey {
        case endpoint, modelID = "id", sizeBytes, family, quantization, contextLength, capabilities, local, error
    }
}

/// A file attached to a user message. Text is extracted by the bridge; images are downscaled JPEGs for vision models.
public struct Attachment: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: String                  // text | pdf | docx | xlsx | html | image
    public var bytes: Int
    public var text: String?
    public var imageBase64: String?
    public var note: String?                 // a warning to show the user (truncated, partly unreadable...)
    public var chars: Int?                   // original text length before any truncation
    public init(id: UUID = UUID(), name: String, kind: String, bytes: Int, text: String? = nil, imageBase64: String? = nil, note: String? = nil, chars: Int? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.bytes = bytes; self.text = text
        self.imageBase64 = imageBase64; self.note = note; self.chars = chars
    }
}

public struct ExtractedFile: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var text: String
    public var chars: Int
    public var truncated: Bool
    public var warning: String?
}

public struct FileUsed: Codable, Sendable, Equatable {
    public var name: String
    public var usedChars: Int
    public var totalChars: Int
    public var excerpted: Bool
}

/// One display-ready thing the assistant did while answering (web search, tool call, memory written/used, notice).
public struct MessageActivity: Codable, Sendable, Equatable, Identifiable {
    public var id: String                    // stable key, e.g. "tool-1", "memory-saved", "notice-0"
    public var kind: String                  // search | tool | memory_saved | memory_used | notice
    public var title: String
    public var detail: String?
    public var status: String?               // running | done | error | waiting_approval
    public var links: [SearchResultItem]
    public var memoryID: String?
    public var output: String?               // terminal output / file preview (shell and file activities)
    public var exitCode: Int?                // terminal exit status (shell activities only)
    public var path: String?                 // absolute path of a created file (file activities only)
    public init(id: String, kind: String, title: String, detail: String? = nil, status: String? = nil,
                links: [SearchResultItem] = [], memoryID: String? = nil, output: String? = nil, exitCode: Int? = nil, path: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.status = status
        self.links = links; self.memoryID = memoryID; self.output = output; self.exitCode = exitCode; self.path = path
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var role: String                      // system | user | assistant | tool
    public var content: String
    public var model: String?
    public var createdAt: Date = Date()
    public var activity: [MessageActivity]?      // optional so conversations saved by older builds still load
    public var attachments: [Attachment]?        // files the user attached to this message
    public init(role: String, content: String, model: String? = nil) {
        self.role = role; self.content = content; self.model = model
    }
    enum CodingKeys: String, CodingKey { case id, role, content, model, createdAt, activity, attachments }
}

public struct SearchResultItem: Codable, Sendable, Equatable, Hashable {
    public var title: String
    public var url: String
    public var snippet: String
    public init(title: String, url: String, snippet: String) { self.title = title; self.url = url; self.snippet = snippet }
}

public struct ToolEvent: Codable, Sendable, Equatable {
    public var id: Int?
    public var name: String
    public var query: String?
    public var status: String
    public var results: [SearchResultItem]?
    public var error: String?
    public var args: [String: JSONValue]?
    public var output: String?               // terminal tool: what the command printed (already trimmed by the bridge)
    public var exitCode: Int?                // terminal tool: process exit status
}
public struct MemorySaved: Codable, Sendable, Equatable { public var id: String; public var content: String; public var category: String }
public struct MemoryRef: Codable, Sendable, Equatable { public var id: String; public var content: String }
public struct ApprovalEvent: Codable, Sendable, Equatable { public var id: String; public var tool: String; public var args: [String: JSONValue]? }

/// One server-sent event of a chat. Exactly one "kind" of field is normally set; all are optional on purpose.
public struct ChatEvent: Codable, Sendable, Equatable {
    public var delta: String?
    public var done: Bool?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var error: APIErrorPayload?
    public var tool: ToolEvent?
    public var memorySaved: MemorySaved?
    public var memoryUsed: [MemoryRef]?
    public var notice: String?
    public var approval: ApprovalEvent?
    public var filesUsed: [FileUsed]?
    public var pageUsed: PageUsed?           // the open browser page was given to the model
    public var vaultUsed: [VaultRef]?        // notes from the Obsidian vault were given to the model
    public var vaultSaved: VaultRef?         // the assistant created a new note in the vault
    public var thinking: Bool?               // a reasoning model is thinking (no visible text yet)
    public var ping: Bool?                   // heartbeat: the bridge is alive and waiting
}

public struct MemoryRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var category: String
    public var content: String
    public var status: String                    // confirmed | proposed | unverified | inferred
    public var source: String
    public var created: Double
    public var project: String?
    public var agentId: String?
    public var confidence: Double
    public var sensitivity: String
    public var conflictsWith: String?
}

public struct MemoryHit: Codable, Sendable, Identifiable, Equatable {
    public var memory: MemoryRecord
    public var score: Double
    public var why: [String: JSONValue]
    public var id: String { memory.id }
}

public struct Approval: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var tool: String
    public var target: String
    public var agent: String?
    public var args: [String: JSONValue]
    public var flags: [String]
}

public struct AgentNode: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var role: String
    public var enabled: Bool
    public var children: [AgentNode]
}

public struct TraceEvent: Codable, Sendable, Equatable, Identifiable {
    public var ts: Double
    public var kind: String
    public var detail: [String: JSONValue]
    public var id: String { "\(ts)-\(kind)" }
}

public struct RunResult: Codable, Sendable, Equatable {
    public struct Tokens: Codable, Sendable, Equatable { public var prompt: Int; public var completion: Int }
    public var id: String
    public var state: String                     // succeeded | failed | cancelled
    public var output: String
    public var error: String?
    public var model: String?
    public var degraded: Bool
    public var tokens: Tokens
    public var durationS: Double?
    public var trace: [TraceEvent]
}

public struct MCPTool: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var trusted: Bool
    public var id: String { name }
}

/// One MCP server = one JSON file. `configText` is the raw file (never decoded as a dictionary, which would rewrite key names).
public struct MCPServer: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var error: String?                    // the file could not be read/validated
    public var configText: String?
    public var summary: String
    public var warnings: [String]
    public var envNames: [String]
    public var approved: Bool
    public var enabled: Bool
    public var state: String                     // disconnected | connecting | ready | failed
    public var connectionError: String?
    public var advertised: [String]
    public var tools: [MCPTool]
    public var logTail: [String]
    public var id: String { name }
    enum CodingKeys: String, CodingKey {
        case name, error, configText, summary, warnings, envNames, approved, enabled, state, connectionError, advertised, tools, logTail
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var webSearchMode: String             // off | keyword | auto
    public var webSearchConsented: Bool
    public var webSearchMaxResults: Int
    public var memoryAutoInject: Bool
    public var attachmentContextChars: Int
    public var webSearchActive: Bool
    public var offlineMode: Bool
    public var shellEnabled: Bool?               // optional so an older bridge still decodes
    public var filesEnabled: Bool?
    public var readPaths: Bool?                  // files and folders named by path in a message are read and given to the model
    public var browserEnabled: Bool?
    public var pageContextChars: Int?
    public var obsidianEnabled: Bool?
    public var obsidianVaultPath: String?
    public var obsidianAutoContext: Bool?
    public var obsidianStoreMemories: Bool?
    public var obsidianAllowWrite: Bool?
    public var obsidianContextChars: Int?
    public var obsidianAgentFolder: String?
}

/// The sandboxed terminal as the bridge sees it on this Mac.
public struct ShellStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var workspace: String
    public var node: String?                     // nil = Node.js was not found
    public var sandbox: String                   // seatbelt | none
    public var allowed: [String]
    public var javascriptReady: Bool
}

public struct SandboxCheck: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var ok: Bool
    public var detail: String
    public var id: String { name }
}
public struct SandboxSelfTest: Codable, Sendable, Equatable {
    public var ok: Bool
    public var checks: [SandboxCheck]
}

/// Minimal JSON value for free-form detail payloads.
public enum JSONValue: Codable, Sendable, Equatable, CustomStringConvertible {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var description: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return v.rounded() == v ? String(Int(v)) : String(v)
        case .bool(let v): return String(v)
        case .array(let v): return "[" + v.map(\.description).joined(separator: ", ") + "]"
        case .object(let v): return "{" + v.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ") + "}"
        case .null: return "null"
        }
    }
}

// MARK: Profile (Settings → Profile)

/// Who the user is, how they like answers, and their own standing instructions. `compiled` is exactly what the model receives each turn
/// (terse on purpose) and `tokens` its estimated cost, so the Profile page can show what the text costs.
public struct UserProfile: Codable, Sendable, Equatable {
    public var callMe = "", name = "", pronouns = "", language = "", timeZone = "", role = "", about = ""
    public var directness = "", formality = "", length = "", humor = "", emoji = "", feedback = ""
    public var instructions = ""
    public var include = true
    public var onboarded = false
    public var compiled = ""
    public var chars = 0, tokens = 0, maxChars = 1600
    public var limits: [String: Int] = [:]
    public var choices: [String: [String]] = [:]
    public var updated: Double = 0
    public init() {}
}

/// What the model would receive for values that are not saved yet, and what that costs. Powers the live token meter.
public struct ProfilePreview: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var compiled: String
    public var chars: Int
    public var tokens: Int
    public var maxChars: Int
}

/// The fields to change; anything left nil stays as it is.
public struct ProfileUpdate: Encodable, Sendable {
    public var callMe: String?, name: String?, pronouns: String?, language: String?, timeZone: String?, role: String?, about: String?
    public var directness: String?, formality: String?, length: String?, humor: String?, emoji: String?, feedback: String?
    public var instructions: String?
    public var include: Bool?, onboarded: Bool?
    public init(callMe: String? = nil, name: String? = nil, pronouns: String? = nil, language: String? = nil, timeZone: String? = nil,
                role: String? = nil, about: String? = nil, directness: String? = nil, formality: String? = nil, length: String? = nil,
                humor: String? = nil, emoji: String? = nil, feedback: String? = nil, instructions: String? = nil,
                include: Bool? = nil, onboarded: Bool? = nil) {
        self.callMe = callMe; self.name = name; self.pronouns = pronouns; self.language = language; self.timeZone = timeZone
        self.role = role; self.about = about; self.directness = directness; self.formality = formality; self.length = length
        self.humor = humor; self.emoji = emoji; self.feedback = feedback; self.instructions = instructions
        self.include = include; self.onboarded = onboarded
    }
}
