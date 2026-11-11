import Foundation

public struct Conversation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var endpoint: String?
    public var model: String?
    public var temporary: Bool          // temporary conversations are never written to disk
    public var messages: [ChatMessage]
    public init(id: UUID = UUID(), title: String = "New conversation", endpoint: String? = nil, model: String? = nil,
                temporary: Bool = false, messages: [ChatMessage] = []) {
        self.id = id; self.title = title; self.createdAt = Date(); self.updatedAt = Date()
        self.endpoint = endpoint; self.model = model; self.temporary = temporary; self.messages = messages
    }
}

/// One JSON file per conversation, written atomically. A corrupt file is quarantined, never fatal.
/// (Planned: migrate to SQLite so conversations share the bridge's migration framework; see docs/implementation-status.md.)
public final class ConversationStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let fm = FileManager.default
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public init(directory: URL) throws {
        self.directory = directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public func save(_ c: Conversation) throws {
        guard !c.temporary else { return }
        lock.lock(); defer { lock.unlock() }
        try encoder.encode(c).write(to: url(c.id), options: [.atomic])
    }
    public func load(_ id: UUID) -> Conversation? {
        lock.lock(); defer { lock.unlock() }
        return read(url(id))
    }
    public func loadAll() -> [Conversation] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(read).sorted { $0.updatedAt > $1.updatedAt }
    }
    // MARK: Lightweight listing (so launching never decodes every message of every chat)

    private struct Header: Codable {
        var id: UUID; var title: String; var createdAt: Date; var updatedAt: Date
        var endpoint: String?; var model: String?; var temporary: Bool?
    }
    private struct IndexEntry: Codable { var modified: Double; var size: Int; var header: Header }

    /// Every saved conversation WITHOUT its messages (just title, dates and model), for the sidebar. A small cache file remembers
    /// each header, so after the first launch only changed files are opened. Use `load(_:)` to get the messages of one chat.
    public func loadSummaries() -> [Conversation] {
        lock.lock(); defer { lock.unlock() }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []).filter { $0.pathExtension == "json" }
        let cacheURL = directory.appendingPathComponent("index.cache")
        var cache: [String: IndexEntry] = (try? Data(contentsOf: cacheURL)).flatMap { try? decoder.decode([String: IndexEntry].self, from: $0) } ?? [:]
        var out: [Conversation] = []
        var changed = false
        var seen = Set<String>()
        for f in files {
            let name = f.lastPathComponent
            seen.insert(name)
            let values = try? f.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? 0
            let header: Header
            if modified != 0, let e = cache[name], e.modified == modified, e.size == size {
                header = e.header
            } else if let d = try? Data(contentsOf: f, options: .mappedIfSafe), let h = try? decoder.decode(Header.self, from: d) {
                header = h; cache[name] = IndexEntry(modified: modified, size: size, header: h); changed = true
            } else {
                _ = read(f)                    // unreadable: quarantine it exactly as a full load would
                continue
            }
            var c = Conversation(id: header.id, title: header.title, endpoint: header.endpoint, model: header.model,
                                 temporary: header.temporary ?? false, messages: [])
            c.createdAt = header.createdAt; c.updatedAt = header.updatedAt
            out.append(c)
        }
        for k in cache.keys where !seen.contains(k) { cache[k] = nil; changed = true }
        if changed, let d = try? encoder.encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Ids of conversations whose messages contain `query`. Opens one file at a time and keeps nothing, so searching a big history
    /// never holds it all in memory. Meant to run off the main thread; stops early if the calling task is cancelled.
    public func searchIDs(_ query: String) -> Set<UUID> {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        lock.lock()
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        lock.unlock()
        var ids = Set<UUID>()
        for f in files {
            if Task.isCancelled { break }
            lock.lock(); let c = read(f); lock.unlock()
            if let c, c.messages.contains(where: { $0.content.lowercased().contains(q) }) { ids.insert(c.id) }
        }
        return ids
    }

    public func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if fm.fileExists(atPath: url(id).path) { try fm.removeItem(at: url(id)) }
    }
    public func search(_ query: String) -> [Conversation] {
        let q = query.lowercased()
        return loadAll().filter { $0.title.lowercased().contains(q) || $0.messages.contains { $0.content.lowercased().contains(q) } }
    }
    private func read(_ u: URL) -> Conversation? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        if let c = try? decoder.decode(Conversation.self, from: d) { return c }
        try? fm.moveItem(at: u, to: u.appendingPathExtension("corrupt"))      // quarantine; user data is not deleted
        return nil
    }
    /// Plain-text/Markdown export.
    public static func exportMarkdown(_ c: Conversation) -> String {
        "# \(c.title)\n\n" + c.messages.map { "**\($0.role.capitalized)**\(($0.model).map { " (\($0))" } ?? ""):\n\n\($0.content)\n" }.joined(separator: "\n")
    }
}
