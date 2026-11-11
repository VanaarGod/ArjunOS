import SwiftUI
import AppKit
import JarvisCore

/// Everything the assistant did while answering, shown above the answer text.
struct ActivityList: View {
    let activities: [MessageActivity]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(activities) { a in
                ActivityChip(activity: a)
                    .transition(.scale(scale: 0.92, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(Theme.gentle, value: activities.count)
    }
}

struct ActivityChip: View {
    @Environment(AppModel.self) private var model
    let activity: MessageActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon
                Text(activity.title).font(.callout.weight(.medium)).lineLimit(1)
                if let d = activity.detail, !d.isEmpty, !["memory_used", "files", "vault_used"].contains(activity.kind) {
                    Text(d).font(activity.kind == "shell" ? .system(size: 12.5, design: .monospaced) : .callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                if !activity.links.isEmpty || hasOutput {
                    Button { withAnimation(Theme.snappy) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.down").font(.caption2).rotationEffect(.degrees(expanded ? 180 : 0))
                    }.buttonStyle(.plain).help(expanded ? "Hide" : (activity.kind == "shell" ? "Show output" : (activity.kind == "file" ? "Show what was written" : "Show sources")))
                }
                if activity.kind == "file", activity.status == "done" {
                    Button("Reveal") { model.revealFile(activity) }.buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).help("Show in Finder")
                    Button("Open") { model.openFile(activity) }.buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).help("Open with your default app")
                }
                if activity.kind == "vault_saved", let p = activity.path {
                    Button("Open") { model.openVaultNote(p) }.buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).help("Open this note in Obsidian")
                }
                if activity.kind == "memory_saved", let id = activity.memoryID {
                    Button("Undo") { Task { await model.undoMemory(id) } }.buttonStyle(.plain)
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).help("Delete this memory")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .help(["memory_used", "files"].contains(activity.kind) ? (activity.detail ?? "") : "")

            if expanded && hasOutput { terminalOutput.transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top))) }
            if expanded && !activity.links.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(activity.links.enumerated()), id: \.offset) { i, r in
                        VStack(alignment: .leading, spacing: 2) {
                            if let note = ObsidianLinks.path(fromChipURL: r.url) {
                                Button("[\(i + 1)] \(r.title)") { model.openVaultNote(note) }.buttonStyle(.plain).font(.callout).foregroundStyle(Theme.accent).help("Open in Obsidian")
                            } else if let u = URL(string: r.url), ["http", "https"].contains(u.scheme ?? "") {
                                Link("[\(i + 1)] \(r.title)", destination: u).font(.callout)
                                Text(u.host ?? r.url).font(.caption).foregroundStyle(.secondary)
                            } else { Text("[\(i + 1)] \(r.title)").font(.callout) }
                            if !r.snippet.isEmpty { Text(r.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .onAppear { if isOutputKind && activity.status != "running" && hasOutput { expanded = true } }
        .onChange(of: activity.status) { _, new in
            if isOutputKind && new != "running" && hasOutput { withAnimation(Theme.smooth) { expanded = true } }     // the result slides open by itself
        }
    }

    private var isOutputKind: Bool { activity.kind == "shell" || activity.kind == "file" }
    private var hasOutput: Bool { isOutputKind && !(activity.output ?? "").isEmpty }

    /// What the command printed, in a terminal-looking block.
    private var terminalOutput: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(activity.kind == "file" ? (activity.detail ?? "") : "$ \(activity.detail ?? "")").font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(3)
                Spacer(minLength: 8)
                if let code = activity.exitCode {
                    Text(code == 0 ? "exit 0" : "exit \(code)").font(.caption2.monospaced()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background((code == 0 ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                }
            }
            ScrollView { Text(activity.output ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 220)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    @ViewBuilder private var icon: some View {
        switch activity.status ?? "" {
        case "running": ProgressView().controlSize(.small)
        case "waiting_approval": Image(systemName: "hand.raised.fill").foregroundStyle(Color.orange)
        case "error": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
        default:
            switch activity.kind {
            case "page": Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Theme.accent)
            case "file": Image(systemName: "doc.badge.plus").foregroundStyle(Color.green).symbolEffect(.bounce, value: activity.status)
            case "shell": Image(systemName: "terminal.fill").foregroundStyle(activity.exitCode == nil || activity.exitCode == 0 ? Theme.accent : Color.orange)
            case "search": Image(systemName: "globe").foregroundStyle(Theme.accent)
            case "memory_saved": Image(systemName: "brain.head.profile").foregroundStyle(Color.green)
            case "memory_used": Image(systemName: "brain").foregroundStyle(Color.purple)
            case "vault_used": Image(systemName: "books.vertical").foregroundStyle(Color.teal)
            case "vault_saved": Image(systemName: "square.and.pencil").foregroundStyle(Color.teal)
            case "files": Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Color.mint)
            case "notice": Image(systemName: "info.circle").foregroundStyle(.secondary)
            default: Image(systemName: "wrench.and.screwdriver").foregroundStyle(Theme.accent)
            }
        }
    }
}

/// One-time permission: only the short search QUERY is ever sent to DuckDuckGo.
struct ConsentBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "globe").font(.title3).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Let \(model.assistantName) search the web?").font(.callout.weight(.semibold))
                Text("When a question needs it (or you say “search …”), a short search query—never your conversation—is sent to DuckDuckGo. Every search appears in the chat. Change this anytime in Settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button("Allow") { Task { await model.updateSettings(consent: true) } }.buttonStyle(GlassButtonStyle(prominent: true))
                Button("Not now") { model.searchConsentDismissed = true }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: Theme.accent.opacity(0.25))
    }
}

/// Pending tool approvals, answerable right in the conversation (each approval covers exactly one action).
struct ApprovalBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ForEach(model.approvals) { a in
            Group {
                if a.tool == "shell" { shellCard(a) } else { toolCard(a) }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .bottom)))
        }
    }

    private func toolCard(_ a: Approval) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(Color.orange).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.assistantName) wants to use \(a.tool)").font(.callout.weight(.semibold))
                if !a.args.isEmpty {
                    Text(a.args.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "  ·  "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                }
                Text("Approving allows this one call only.").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            HStack {
                Button("Deny") { Task { await model.resolve(a.id, approve: false) } }.buttonStyle(GlassButtonStyle())
                Button("Approve once") { Task { await model.resolve(a.id, approve: true) } }.buttonStyle(GlassButtonStyle(prominent: true))
            }
        }
        .padding(14).liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: Color.orange.opacity(0.3))
    }

    private func shellCard(_ a: Approval) -> some View {
        let command: String = { if case .string(let c)? = a.args["command"] { return c } else { return "" } }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill").foregroundStyle(Color.orange)
                Text("\(model.assistantName) wants to run a command").font(.callout.weight(.semibold))
            }
            Text("$ \(command)").font(.system(size: 13, design: .monospaced)).textSelection(.enabled).lineLimit(6)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Text("Runs in a sandbox: no network, no sudo, files can't be deleted, and only its own workspace folder is visible.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Deny") { Task { await model.resolve(a.id, approve: false) } }.buttonStyle(GlassButtonStyle())
                Button("Run once") { Task { await model.resolve(a.id, approve: true) } }.buttonStyle(GlassButtonStyle(prominent: true))
            }
        }
        .padding(14).liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: Color.orange.opacity(0.3))
    }
}
