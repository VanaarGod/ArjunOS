import Foundation

public enum BridgeError: Error, LocalizedError, Equatable {
    case http(status: Int, message: String)
    case transport(String)
    case decoding(String)
    case notRunning
    public var errorDescription: String? {
        switch self {
        case .http(let s, let m): return "Bridge returned HTTP \(s): \(m)"
        case .transport(let m): return "Cannot reach the local bridge: \(m)"
        case .decoding(let m): return "Unexpected bridge response: \(m)"
        case .notRunning: return "The local bridge is not running."
        }
    }
}

/// Typed client for the loopback bridge API (v1). The bearer token is generated per launch by BridgeSupervisor.
public actor BridgeClient {
    public let baseURL: URL
    private let token: String
    let session: URLSession
    let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()
    let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }()

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    func makeRequest(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        comps.path = parts[0]
        if parts.count > 1 { comps.percentEncodedQuery = parts[1] }
        var r = URLRequest(url: comps.url!, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func perform<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw BridgeError.transport(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw BridgeError.transport("non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["detail"] ?? $0["error"]) as? String } ?? "request failed"
            throw BridgeError.http(status: http.statusCode, message: msg)
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw BridgeError.decoding(String(describing: error)) }
    }

    public func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try await perform(makeRequest(path), as: type)
    }
    public func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B, as type: T.Type = T.self) async throws -> T {
        let data = try encoder.encode(body)
        return try await perform(makeRequest(path, method: method, body: data), as: type)
    }
    public func send<T: Decodable>(_ method: String, _ path: String, as type: T.Type = T.self) async throws -> T {
        try await perform(makeRequest(path, method: method), as: type)
    }

    // MARK: Typed API
    public func health() async throws -> BridgeHealth { try await get("/v1/health") }
    public func providers() async throws -> [Provider] { try await get("/v1/providers") }
    public func models() async throws -> [ModelEntry] { try await get("/v1/models") }
    public func agentTree() async throws -> [AgentNode] { try await get("/v1/agents/tree") }
    public func approvals() async throws -> [Approval] { try await get("/v1/approvals") }

    public struct ScanResult: Codable, Sendable { public var events: [ScanEvent]; public var logTail: [String] }
    public struct ScanEvent: Codable, Sendable, Equatable { public var type: String; public var endpoint: String; public var detail: String }
    public func scan() async throws -> ScanResult { try await send("POST", "/v1/providers/scan") }

    struct EndpointBody: Encodable { var url: String; var hint: String }
    public struct EndpointAdded: Codable, Sendable { public var key: String; public var status: String }
    public func addEndpoint(url: String, hint: String = "user-configured") async throws -> EndpointAdded {
        try await send("POST", "/v1/providers/endpoints", body: EndpointBody(url: url, hint: hint))
    }

    struct MemoryBody: Encodable { var content: String; var category: String; var project: String?; var confirmed: Bool }
    public func addMemory(_ content: String, category: String, project: String? = nil, confirmed: Bool = false) async throws -> MemoryRecord {
        try await send("POST", "/v1/memory", body: MemoryBody(content: content, category: category, project: project, confirmed: confirmed))
    }
    public func searchMemory(_ q: String, project: String? = nil) async throws -> [MemoryHit] {
        var path = "/v1/memory/search?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        if let p = project { path += "&project=" + (p.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") }
        return try await get(path)
    }
    /// Everything saved, newest first (no search needed), including proposals that are not used in answers yet.
    public func memoryList(limit: Int = 200) async throws -> [MemoryRecord] { try await get("/v1/memory?limit=\(limit)") }
    public func confirmMemory(_ id: String) async throws -> MemoryRecord { try await send("POST", "/v1/memory/\(id)/confirm") }
    public struct Deleted: Codable, Sendable { public var deleted: String }
    public func deleteMemory(_ id: String) async throws { let _: Deleted = try await send("DELETE", "/v1/memory/\(id)") }

    struct ResolveBody: Encodable { var approve: Bool }
    public struct Resolved: Codable, Sendable { public var id: String; public var approved: Bool }
    public func resolveApproval(_ id: String, approve: Bool) async throws {
        let _: Resolved = try await send("POST", "/v1/approvals/\(id)/resolve", body: ResolveBody(approve: approve))
    }

    struct AssignBody: Encodable { var policy: String; var models: [String]; var profile: String; var escalateTo: [String] }
    public struct Assigned: Codable, Sendable { public var agent: String; public var models: [String] }
    public func assignModels(agent: String, models: [String], policy: String = "fixed") async throws {
        let _: Assigned = try await send("PUT", "/v1/agents/\(agent)/models",
                                         body: AssignBody(policy: policy, models: models, profile: "balanced", escalateTo: []))
    }
    struct RunBody: Encodable { var prompt: String }
    public func runAgent(_ id: String, prompt: String) async throws -> RunResult {
        try await send("POST", "/v1/agents/\(id)/run", body: RunBody(prompt: prompt), as: RunResult.self)
    }

    // MARK: File uploads
    /// Sends raw bytes (never a path) to the bridge for text extraction. The filename travels percent-encoded in a header.
    public func extractFile(name: String, data: Data) async throws -> ExtractedFile {
        var req = makeRequest("/v1/files/extract", method: "POST", body: nil, timeout: 120)
        req.httpBody = data
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.setValue(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file", forHTTPHeaderField: "X-Filename")
        return try await perform(req, as: ExtractedFile.self)
    }

    // MARK: Profile
    public func profile() async throws -> UserProfile { try await get("/v1/profile") }
    @discardableResult
    public func updateProfile(_ u: ProfileUpdate) async throws -> UserProfile { try await send("PUT", "/v1/profile", body: u) }
    public func previewProfile(_ u: ProfileUpdate) async throws -> ProfilePreview { try await send("POST", "/v1/profile/preview", body: u) }

    // MARK: Settings & web search
    public func settings() async throws -> AppSettings { try await get("/v1/settings") }
    struct SettingsBody: Encodable {
        var webSearchMode: String?; var webSearchConsented: Bool?; var webSearchMaxResults: Int?; var memoryAutoInject: Bool?
        var attachmentContextChars: Int?
        var shellEnabled: Bool?
        var filesEnabled: Bool?
        var readPaths: Bool?
        var browserEnabled: Bool?
        var pageContextChars: Int?
    }
    @discardableResult
    public func updateSettings(webSearchMode: String? = nil, webSearchConsented: Bool? = nil,
                               webSearchMaxResults: Int? = nil, memoryAutoInject: Bool? = nil,
                               attachmentContextChars: Int? = nil, shellEnabled: Bool? = nil, filesEnabled: Bool? = nil, readPaths: Bool? = nil, browserEnabled: Bool? = nil, pageContextChars: Int? = nil) async throws -> AppSettings {
        try await send("PUT", "/v1/settings", body: SettingsBody(webSearchMode: webSearchMode, webSearchConsented: webSearchConsented,
                                                                 webSearchMaxResults: webSearchMaxResults, memoryAutoInject: memoryAutoInject,
                                                                 attachmentContextChars: attachmentContextChars, shellEnabled: shellEnabled, filesEnabled: filesEnabled, readPaths: readPaths, browserEnabled: browserEnabled, pageContextChars: pageContextChars))
    }

    // MARK: Sandboxed terminal
    public func shellStatus() async throws -> ShellStatus { try await get("/v1/shell/status") }
    /// Runs fixed probes that try to delete / write / spawn / connect / read from INSIDE the sandbox. All must be blocked.
    public func shellSelfTest() async throws -> SandboxSelfTest { try await send("POST", "/v1/shell/selftest") }
    struct SearchTestBody: Encodable { var query: String }
    public struct SearchTestResult: Codable, Sendable { public var query: String; public var results: [SearchResultItem] }
    public func testWebSearch(_ query: String = "DuckDuckGo") async throws -> SearchTestResult {
        try await send("POST", "/v1/tools/web_search/test", body: SearchTestBody(query: query))
    }

    // MARK: MCP (one JSON file per server)
    public func mcpServers() async throws -> [MCPServer] { try await get("/v1/mcp/servers") }
    public struct DirectoryInfo: Codable, Sendable { public var path: String }
    public func mcpDirectory() async throws -> String { (try await get("/v1/mcp/directory", as: DirectoryInfo.self)).path }
    struct TextBody: Encodable { var text: String }
    struct ImportBody: Encodable { var text: String; var name: String?; var overwrite: Bool }
    public struct Created: Codable, Sendable { public var created: [String] }
    public func saveMCPServer(name: String, text: String) async throws -> MCPServer {
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return try await send("PUT", "/v1/mcp/servers/\(n)", body: TextBody(text: text))
    }
    public func importMCP(text: String, name: String? = nil, overwrite: Bool = false) async throws -> [String] {
        (try await send("POST", "/v1/mcp/servers/import", body: ImportBody(text: text, name: name, overwrite: overwrite), as: Created.self)).created
    }
    public struct Ack: Codable, Sendable {}
    public func deleteMCPServer(_ name: String) async throws { let _: Ack = try await send("DELETE", "/v1/mcp/servers/\(name)") }
    public func approveMCPServer(_ name: String) async throws { let _: Ack = try await send("POST", "/v1/mcp/servers/\(name)/approve") }
    public func connectMCPServer(_ name: String) async throws -> MCPServer { try await send("POST", "/v1/mcp/servers/\(name)/connect") }
    public func disconnectMCPServer(_ name: String) async throws { let _: Ack = try await send("POST", "/v1/mcp/servers/\(name)/disconnect") }
    struct TrustBody: Encodable { var trusted: Bool }
    public func trustMCPTool(server: String, tool: String, trusted: Bool) async throws {
        let t = tool.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tool
        let _: Ack = try await send("POST", "/v1/mcp/servers/\(server)/tools/\(t)/trust", body: TrustBody(trusted: trusted))
    }

    // MARK: Streaming chat
    struct ChatBody: Encodable {
        struct Att: Encodable {
            var name: String; var kind: String; var text: String?; var imageB64: String?; var note: String?
            enum CodingKeys: String, CodingKey { case name, kind, text, imageB64 = "image_b64", note }
        }
        struct Msg: Encodable { var role: String; var content: String; var attachments: [Att]? }
        var endpoint: String; var model: String; var messages: [Msg]
        var page: PagePayload?               // the active browser tab, when the user wants to ask about it
    }
    /// Streams events; cancelling the consuming Task cancels the HTTP request.
    public func chatStream(endpoint: String, model: String, messages: [ChatMessage], page: PagePayload? = nil) throws -> AsyncThrowingStream<ChatEvent, Error> {
        let body = ChatBody(endpoint: endpoint, model: model, messages: messages.map { m in
            .init(role: m.role, content: m.content, attachments: m.attachments?.map {
                .init(name: $0.name, kind: $0.kind, text: $0.text, imageB64: $0.imageBase64, note: $0.note) })
        }, page: page)
        let req = makeRequest("/v1/chat", method: "POST", body: try encoder.encode(body), timeout: 600)
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
                        do { continuation.yield(try decoder.decode(ChatEvent.self, from: data)) }
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
