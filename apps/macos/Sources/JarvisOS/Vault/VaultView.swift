import SwiftUI
import AppKit
import JarvisCore

/// Knowledge: your Obsidian vault. Search it, read notes, and see what the assistant stores there.
struct VaultView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let vault = model.vault
        Group {
            if vault.status == nil { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !vault.active { ConnectCard() }
            else { Browser() }
        }
        .task { model.vault.attach(model); await model.vault.refresh() }
    }
}

// MARK: - Not connected yet

private struct ConnectCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let vault = model.vault
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Connect your Obsidian vault", systemImage: "books.vertical").font(.title2.weight(.semibold))
                    Text("Your notes become the assistant's knowledge base, and its memories are stored in your vault as plain Markdown notes you can read, edit and delete in Obsidian. Everything stays on this Mac.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let issue = vault.status?.issue, vault.status?.configured == true {
                    Label(issue, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !vault.discovered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("VAULTS OBSIDIAN KNOWS ABOUT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                        ForEach(vault.discovered) { v in
                            Button { Task { await vault.connect(path: v.path) } } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(v.name).font(.callout.weight(.medium))
                                        Text(v.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    if v.open { Text("open now").font(.caption2).foregroundStyle(.green) }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(12).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }.buttonStyle(.plain).disabled(vault.busy)
                        }
                    }
                }
                HStack {
                    Button { vault.chooseFolder() } label: { Label("Choose a folder…", systemImage: "folder.badge.plus") }.buttonStyle(GlassButtonStyle(prominent: vault.discovered.isEmpty)).disabled(vault.busy)
                    if vault.busy { ProgressView().controlSize(.small); Text("Reading your notes…").font(.caption).foregroundStyle(.secondary) }
                }
                if let e = vault.error { ErrorStrip(text: e) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHAT HAPPENS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                    bullet("Any model can search and read your notes, and the notes that match a question are added automatically.")
                    bullet("The assistant never edits your own notes. It can create new ones in an “ArjunOS” folder, and append only to those.")
                    bullet("Memories are stored as notes in ArjunOS/Memories. Edit or delete one in Obsidian and the memory follows.")
                    bullet("Secrets and sensitive memories are never written into the vault, and hidden folders such as .obsidian are never read.")
                }
            }
            .padding(24).frame(maxWidth: 640, alignment: .leading)
        }
    }
    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) { Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent).font(.caption); Text(t).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}

// MARK: - Connected: search, read, manage

private struct Browser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let vault = model.vault
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                left.frame(width: 330)
                Divider().opacity(0.4)
                NotePreview()
            }
        }
        .onChange(of: vault.query) { _, _ in vault.scheduleSearch() }
    }

    private var header: some View {
        let vault = model.vault, s = vault.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s?.vaultName ?? "Vault").font(.headline)
                    Text("\(s?.notes ?? 0) notes" + (s?.lastIndex.map { " · indexed " + Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)) } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if vault.busy { ProgressView().controlSize(.small) }
                Button { Task { await vault.reindex() } } label: { Label("Re-scan", systemImage: "arrow.clockwise") }.buttonStyle(GlassButtonStyle()).disabled(vault.busy).help("Pick up notes you added or changed")
                if model.settings?.obsidianStoreMemories != false {
                    Button { Task { await vault.syncMemories() } } label: { Label("Sync memories", systemImage: "brain") }.buttonStyle(GlassButtonStyle()).disabled(vault.busy).help("Match memories with the notes in \(s?.memoriesFolder ?? "ArjunOS/Memories")")
                }
                Button { vault.chooseFolder() } label: { Text("Change vault") }.buttonStyle(GlassButtonStyle())
                Button { model.settingsSection = .obsidian; model.selection = .settings } label: { Image(systemName: "gearshape") }.buttonStyle(GlassButtonStyle()).help("Obsidian settings")
            }
            if let m = vault.message { Label(m, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            if let e = vault.error { ErrorStrip(text: e) }
            if let w = s?.lastSync?.warnings.first { Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var left: some View {
        @Bindable var vault = model.vault
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your notes", text: $vault.query).textFieldStyle(.plain)
                if vault.searching { ProgressView().controlSize(.mini) }
                else if !vault.query.isEmpty { Button { vault.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain) }
            }
            .padding(10).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !vault.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        if vault.hits.isEmpty && !vault.searching { Text("No notes match.").font(.callout).foregroundStyle(.secondary).padding(8) }
                        ForEach(vault.hits) { h in HitRow(hit: h) }
                    } else if let r = vault.recent {
                        if !r.tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) { ForEach(r.tags.prefix(20)) { t in Button { vault.query = "#" + t.tag; vault.scheduleSearch() } label: { Text("#\(t.tag) \(t.count)").font(.caption) }.buttonStyle(GlassButtonStyle()) } }
                            }.padding(.bottom, 4)
                        }
                        Text("RECENT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6).padding(.horizontal, 4)
                        ForEach(r.notes) { n in
                            Button { Task { await vault.openNote(n.rel) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.title).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(n.rel).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain).hoverFill(cornerRadius: 8)
                        }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }
}

private struct HitRow: View {
    @Environment(AppModel.self) private var model
    let hit: VaultHit
    var body: some View {
        Button { Task { await model.vault.openNote(hit.path) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title).font(.callout.weight(.medium)).lineLimit(1)
                if let h = hit.heading, !h.isEmpty { Text(h).font(.caption).foregroundStyle(Theme.accent).lineLimit(1) }
                Text(hit.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Text(hit.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain).hoverFill(cornerRadius: 10)
    }
}

private struct NotePreview: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let vault = model.vault
        Group {
            if vault.loadingNote { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let n = vault.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(n.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                            Spacer()
                            Button { vault.openInObsidian(n.path) } label: { Label("Open in Obsidian", systemImage: "arrow.up.forward.app") }.buttonStyle(GlassButtonStyle(prominent: true))
                        }
                        HStack(spacing: 6) {
                            Text(n.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if n.agentNote { Text("created by \(model.assistantName)").font(.caption2).padding(.horizontal, 7).padding(.vertical, 2).background(Theme.accent.opacity(0.2), in: Capsule()) }
                        }
                        if !n.tags.isEmpty { HStack(spacing: 6) { ForEach(n.tags, id: \.self) { Text("#\($0)").font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(Color.white.opacity(0.08), in: Capsule()) } } }
                        RichText(key: "vault-" + n.path + String(n.mtime), markdown: n.body)
                        if n.truncated { Text("Shortened for display. Open it in Obsidian to read the rest.").font(.caption).foregroundStyle(.secondary) }
                        let outgoing = n.links.filter { $0.path != nil }
                        if !outgoing.isEmpty { linkRow("Links to", outgoing.map { ($0.name, $0.path!) }) }
                        if !n.backlinks.isEmpty { linkRow("Linked from", n.backlinks.map { (($0 as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""), $0) }) }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Search for a note or pick a recent one").foregroundStyle(.secondary)
                    Text("\(model.assistantName) uses this vault automatically when your question matches your notes.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func linkRow(_ title: String, _ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            FlowRow(items: items)
        }
    }
}

private struct FlowRow: View {
    @Environment(AppModel.self) private var model
    let items: [(String, String)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Button { Task { await model.vault.openNote(it.1) } } label: { Label(it.0, systemImage: "link").font(.caption).lineLimit(1) }.buttonStyle(GlassButtonStyle())
            }
        }
    }
}
