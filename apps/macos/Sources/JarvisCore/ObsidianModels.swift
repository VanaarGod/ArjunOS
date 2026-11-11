import Foundation

// MARK: - Obsidian vault (the knowledge base, and where memories are stored)

public struct ObsidianSyncReport: Codable, Sendable, Equatable {
    public var written: Int
    public var imported: Int
    public var memoryUpdated: Int
    public var noteUpdated: Int
    public var notesDeleted: Int
    public var memoriesDeleted: Int
    public var warnings: [String]
    public var at: Double?
    public var changes: Int { written + imported + memoryUpdated + noteUpdated + notesDeleted + memoriesDeleted }
}

public struct ObsidianStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var configured: Bool
    public var active: Bool                    // enabled AND the folder is readable right now
    public var vaultPath: String
    public var vaultName: String
    public var issue: String?                  // why it is not active, in plain words
    public var notes: Int
    public var chunks: Int
    public var agentFolder: String
    public var memoriesFolder: String
    public var fts: Bool
    public var lastIndex: Double?
    public var lastSync: ObsidianSyncReport?
}

public struct DiscoveredVault: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    public var name: String
    public var open: Bool
    public var id: String { path }
}

public struct VaultHit: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    public var title: String
    public var heading: String?
    public var excerpt: String
    public var score: Double
    public var tags: [String]
    public var id: String { path + "#" + (heading ?? "") }
}

public struct VaultLink: Codable, Sendable, Equatable, Hashable { public var name: String; public var path: String? }

public struct VaultNote: Codable, Sendable, Equatable {
    public var path: String
    public var title: String
    public var tags: [String]
    public var aliases: [String]
    public var body: String
    public var truncated: Bool
    public var links: [VaultLink]
    public var backlinks: [String]
    public var mtime: Double
    public var agentNote: Bool                 // created by the assistant (it may append to these, never to yours)
}

public struct VaultRecent: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable, Identifiable { public var rel: String; public var title: String; public var mtime: Double; public var tags: [String]; public var id: String { rel } }
    public struct TagCount: Codable, Sendable, Equatable, Identifiable { public var tag: String; public var count: Int; public var id: String { tag } }
    public var notes: [Item]
    public var tags: [TagCount]
}

/// A note the assistant used or created while answering (shown as a chip on the message).
public struct VaultRef: Codable, Sendable, Equatable { public var path: String; public var title: String; public var heading: String? }

public enum ObsidianLinks {
    /// obsidian://open?vault=NAME&file=Folder/Note (Obsidian wants the path without ".md").
    public static func openURL(vaultName: String, path: String) -> URL? {
        var c = URLComponents(); c.scheme = "obsidian"; c.host = "open"
        let file = path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
        c.percentEncodedQuery = "vault=" + enc(vaultName) + "&file=" + enc(file)
        return c.url
    }
    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&+=#?/ ")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    /// A `vault:` link as used inside message chips.
    public static func chipURL(_ path: String) -> String { "vault:" + path }
    public static func path(fromChipURL s: String) -> String? { s.hasPrefix("vault:") ? String(s.dropFirst(6)) : nil }
}

// MARK: - Client

extension BridgeClient {
    struct ConnectBody: Encodable { var path: String }
    struct ReindexBody: Encodable { var force: Bool }
    struct NoteBody: Encodable { var title: String; var body: String; var tags: [String] }
    struct VaultsBody: Decodable { var vaults: [DiscoveredVault] }
    public struct CreatedNote: Codable, Sendable { public var path: String; public var title: String; public var renamed: Bool }
    struct ObsidianSettingsBody: Encodable {
        var obsidianEnabled: Bool?; var obsidianAutoContext: Bool?; var obsidianStoreMemories: Bool?; var obsidianAllowWrite: Bool?
        var obsidianContextChars: Int?
    }
    struct Report: Decodable { var report: ObsidianSyncReport? }

    public func obsidianStatus() async throws -> ObsidianStatus { try await get("/v1/obsidian/status") }
    public func obsidianDiscover() async throws -> [DiscoveredVault] { let v: VaultsBody = try await get("/v1/obsidian/discover"); return v.vaults }
    public func obsidianConnect(path: String) async throws -> ObsidianStatus { try await send("POST", "/v1/obsidian/connect", body: ConnectBody(path: path)) }
    public func obsidianReindex(force: Bool = false) async throws -> ObsidianStatus { try await send("POST", "/v1/obsidian/reindex", body: ReindexBody(force: force)) }
    public func obsidianSyncMemories() async throws -> ObsidianSyncReport { try await send("POST", "/v1/obsidian/memories/sync") }
    public func obsidianSearch(_ q: String, limit: Int = 12) async throws -> [VaultHit] {
        try await get("/v1/obsidian/search?q=\(ObsidianLinks.enc(q))&limit=\(limit)")
    }
    public func obsidianNote(path: String) async throws -> VaultNote { try await get("/v1/obsidian/note?path=\(ObsidianLinks.enc(path))") }
    public func obsidianRecent() async throws -> VaultRecent { try await get("/v1/obsidian/recent?limit=30") }
    public func obsidianCreateNote(title: String, body: String, tags: [String] = []) async throws -> CreatedNote {
        try await send("POST", "/v1/obsidian/note", body: NoteBody(title: title, body: body, tags: tags))
    }
    @discardableResult
    public func updateObsidianSettings(enabled: Bool? = nil, autoContext: Bool? = nil, storeMemories: Bool? = nil, allowWrite: Bool? = nil, contextChars: Int? = nil) async throws -> AppSettings {
        try await send("PUT", "/v1/settings", body: ObsidianSettingsBody(obsidianEnabled: enabled, obsidianAutoContext: autoContext, obsidianStoreMemories: storeMemories,
                                                                         obsidianAllowWrite: allowWrite, obsidianContextChars: contextChars))
    }
}
