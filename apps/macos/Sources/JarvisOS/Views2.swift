import SwiftUI
import AppKit
import JarvisCore

// MARK: Memory
struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var q = ""
    @State private var newText = ""
    @State private var category = "knowledge"
    @State private var confirm = false
    @State private var searchTask: Task<Void, Never>?
    private static let categories = ["knowledge", "preference", "conversation", "project", "task", "episodic", "procedural"]
    private var searching: Bool { !q.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Memory").font(.largeTitle.bold())
                Text("Say “remember …” in any chat and \(model.assistantName) writes a note here. Relevant notes are used automatically when they match what you ask. Everything is stored on this Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                searchField
                addCard
                if searching { results } else { saved }
            }
            .padding(24).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .task { await model.refreshMemories() }                      // everything is listed the moment this screen opens
        .onChange(of: q) { _, new in
            searchTask?.cancel()
            guard !new.trimmingCharacters(in: .whitespaces).isEmpty else { model.memoryHits = []; return }
            searchTask = Task { try? await Task.sleep(nanoseconds: 250_000_000); if !Task.isCancelled { await model.searchMemory(new) } }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter your memories", text: $q).textFieldStyle(.plain).onSubmit { Task { await model.searchMemory(q) } }
            if searching { Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Clear") }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var addCard: some View {
        SettingsGroup("Add a memory yourself", footer: "Preferences are saved as proposals unless you confirm them. Unconfirmed items are never used in answers.") {
            SettingBlock { TextField("What should be remembered?", text: $newText).glassField() }
            SettingRow("Category") {
                DropdownPicker(options: Self.categories.map { SettingOption(value: $0, title: $0.capitalized) }, selection: $category, minWidth: 140, menuWidth: 200)
            }
            if category == "preference" {
                SettingToggleRow(title: "Confirm as a long-term preference", subtitle: "Confirmed preferences are used in answers right away.", isOn: $confirm)
            }
            SettingRow("") {
                Button("Save") { let t = newText; newText = ""; Task { await model.addMemory(t, category: category, confirmed: confirm) } }
                    .buttonStyle(GlassButtonStyle()).disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder private var saved: some View {
        let items = model.memoryItems
        HStack {
            Text(items.isEmpty ? "SAVED" : "SAVED · \(items.count)").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            Spacer()
        }.padding(.horizontal, 6)
        if items.isEmpty {
            Text(model.memoriesLoaded ? "Nothing saved yet. Say “remember …” in a chat, or add one above." : "Loading…").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 6)
        }
        ForEach(items) { r in
            MemoryCard(record: r, why: nil,
                       confirm: { Task { await model.confirm(r.id, query: "") } },
                       delete: { Task { await model.deleteMemory(r.id, query: "") } })
        }
    }

    @ViewBuilder private var results: some View {
        Text(model.memoryHits.isEmpty ? "NO MATCHES" : "RESULTS · \(model.memoryHits.count)").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary).padding(.horizontal, 6)
        ForEach(model.memoryHits) { h in
            MemoryCard(record: h.memory,
                       why: h.why.sorted { $0.key < $1.key }.compactMap { $0.value == .null ? nil : "\($0.key)=\($0.value)" }.joined(separator: ", "),
                       confirm: { Task { await model.confirm(h.memory.id, query: q) } },
                       delete: { Task { await model.deleteMemory(h.memory.id, query: q) } })
        }
    }
}

private struct MemoryCard: View {
    let record: MemoryRecord
    let why: String?
    let confirm: () -> Void
    let delete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.content).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(record.category.capitalized).font(.caption).foregroundStyle(.secondary)
                Text(record.status == "confirmed" ? "Confirmed" : "Proposed — not used yet")
                    .font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background((record.status == "confirmed" ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                    .foregroundStyle(record.status == "confirmed" ? Color.green : Color.orange)
                Text("source: \(record.source)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if record.status != "confirmed" { Button("Confirm", action: confirm).buttonStyle(GlassButtonStyle()).controlSize(.small) }
                Button("Delete", role: .destructive, action: delete).buttonStyle(GlassButtonStyle()).controlSize(.small)
            }
            if let why, !why.isEmpty { Text("Why retrieved: " + why).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: Tasks
struct TasksView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pending approvals").font(.largeTitle.bold())
                Text("Each approval covers exactly one action (tool + arguments), expires after 5 minutes, and can't be reused.").font(.callout).foregroundStyle(.secondary)
                if model.approvals.isEmpty { Text("Nothing is waiting for you.").foregroundStyle(.secondary) }
                ForEach(model.approvals) { a in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(a.tool).font(.headline.monospaced())
                        Text("Agent: \(a.agent ?? "—")" + (a.target.isEmpty ? "" : "  ·  Target: \(a.target)")).font(.caption)
                        if !a.flags.isEmpty { Text("Flags: " + a.flags.joined(separator: ", ")).font(.caption).foregroundStyle(Color.orange) }
                        Text("Arguments: " + a.args.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")).font(.caption.monospaced())
                        HStack {
                            Button("Approve once") { Task { await model.resolve(a.id, approve: true) } }.buttonStyle(.borderedProminent)
                            Button("Deny", role: .destructive) { Task { await model.resolve(a.id, approve: false) } }
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Text("Scheduled jobs, downloads and indexing monitors are not implemented yet.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
    }
}

// MARK: System
struct SystemView: View {
    @Environment(AppModel.self) private var model
    @State private var tail: [String] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("System").font(.largeTitle.bold())
                BridgeBadge()
                card("Engines", model.providers.isEmpty ? "None probed yet." : model.providers.map { "\($0.kind) @ \($0.key): \($0.status)" }.joined(separator: "\n"))
                card("MCP servers", model.mcpServers.isEmpty ? "None configured." : model.mcpServers.map { "\($0.name): \($0.error == nil ? $0.state : "file error")" }.joined(separator: "\n"))
                card("Web search", searchSummary)
                card("Provider scan log", model.scanLog.isEmpty ? "No scan yet." : model.scanLog.joined(separator: "\n"))
                card("Bridge diagnostics (stderr)", tail.isEmpty ? "Empty." : tail.suffix(30).joined(separator: "\n"))
                Button("Refresh") { Task { await model.refreshAll(); await model.refreshMCP(); await model.refreshSettings(); tail = await model.supervisor.diagnosticsTail() } }
                Text("CPU/GPU/energy metrics and token-cost dashboards are not implemented; nothing here is estimated or invented.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }.task { tail = await model.supervisor.diagnosticsTail() }
    }
    private var searchSummary: String {
        guard let st = model.settings else { return "Unknown" }
        if st.webSearchActive { return "On (\(st.webSearchMode))" }
        return st.webSearchConsented ? "Off" : "Waiting for your permission"
    }
    private func card(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.padding(14).liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
