import SwiftUI
import AppKit
import JarvisCore

/// The Obsidian vault as the app sees it: connection state, search, and the note being previewed.
@MainActor @Observable
final class VaultModel {
    var status: ObsidianStatus?
    var discovered: [DiscoveredVault] = []
    var busy = false
    var message: String?                      // something good that happened ("Synced 3 memories")
    var error: String?
    var query = ""
    var hits: [VaultHit] = []
    var searching = false
    var recent: VaultRecent?
    var selected: VaultNote?
    var loadingNote = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var active: Bool { status?.active == true }
    var configured: Bool { status?.configured == true }

    func attach(_ app: AppModel) { self.app = app }

    // MARK: connection

    func refresh() async {
        guard let c = app?.bridge else { return }
        if let s = try? await c.obsidianStatus() { status = s }
        if active, let r = try? await c.obsidianRecent() { recent = r }
        if !active { discovered = (try? await c.obsidianDiscover()) ?? [] }
    }

    func connect(path: String) async {
        guard let c = app?.bridge else { return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            status = try await c.obsidianConnect(path: path)
            await app?.refreshSettings()
            if let r = try? await c.obsidianRecent() { recent = r }
            message = "Connected to \(status?.vaultName ?? "your vault"): \(status?.notes ?? 0) notes."
        } catch { self.error = error.localizedDescription }
    }

    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = "Choose your Obsidian vault (the folder that holds your notes)"; p.prompt = "Use this vault"
        if p.runModal() == .OK, let url = p.url { Task { await connect(path: url.path) } }
    }

    func disconnect() async {
        guard let c = app?.bridge else { return }
        if (try? await c.updateObsidianSettings(enabled: false)) != nil { await app?.refreshSettings() }
        selected = nil; hits = []; recent = nil
        await refresh()
    }

    func set(enabled: Bool? = nil, autoContext: Bool? = nil, storeMemories: Bool? = nil, allowWrite: Bool? = nil) async {
        guard let c = app?.bridge else { return }
        error = nil
        do { _ = try await c.updateObsidianSettings(enabled: enabled, autoContext: autoContext, storeMemories: storeMemories, allowWrite: allowWrite) }
        catch { self.error = error.localizedDescription }
        await app?.refreshSettings(); await refresh()
        if storeMemories == true || enabled == true { await syncMemories(quiet: true) }
    }

    func reindex(force: Bool = false) async {
        guard let c = app?.bridge else { return }
        busy = true; defer { busy = false }
        do { status = try await c.obsidianReindex(force: force); message = "Indexed \(status?.notes ?? 0) notes." }
        catch { self.error = error.localizedDescription }
        if let r = try? await c.obsidianRecent() { recent = r }
    }

    func syncMemories(quiet: Bool = false) async {
        guard let c = app?.bridge else { return }
        if !quiet { busy = true }
        defer { busy = false }
        do {
            let r = try await c.obsidianSyncMemories()
            if !quiet { message = r.changes == 0 ? "Memories and notes are already in sync." : "Synced memories: \(r.written) written, \(r.imported) imported, \(r.memoryUpdated + r.noteUpdated) updated, \(r.notesDeleted + r.memoriesDeleted) removed." }
            if let w = r.warnings.first { error = w }
        } catch { if !quiet { self.error = error.localizedDescription } }
        await refresh()
    }

    // MARK: search and notes

    func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { hits = []; searching = false; return }
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, let c = self.app?.bridge else { return }
            do { self.hits = try await c.obsidianSearch(q) } catch { self.hits = []; self.error = error.localizedDescription }
            self.searching = false
        }
    }

    func openNote(_ path: String) async {
        guard let c = app?.bridge else { return }
        loadingNote = true; defer { loadingNote = false }
        do { selected = try await c.obsidianNote(path: path); error = nil }
        catch { self.error = "Couldn't open that note: \(error.localizedDescription)" }
    }

    /// Opens the note in the Obsidian app; if Obsidian isn't installed, shows the file in Finder instead.
    func openInObsidian(_ path: String) {
        guard let s = status else { return }
        if let url = ObsidianLinks.openURL(vaultName: s.vaultName, path: path), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.vaultPath).appendingPathComponent(path)])
    }

    func saveToVault(title: String, body: String) async -> String? {
        guard let c = app?.bridge else { return nil }
        do { let n = try await c.obsidianCreateNote(title: title, body: body); message = "Saved to \(n.path)"; await refresh(); return n.path }
        catch { self.error = error.localizedDescription; return nil }
    }
}
