import SwiftUI
import AppKit
import JarvisCore

private struct EditTarget: Identifiable {
    let id = UUID()
    var name: String
    var text: String
    var isNew: Bool
}

private let stdioTemplate = """
{
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Documents"],
  "env": {}
}
"""
private let remoteTemplate = """
{
  "url": "https://example.com/mcp",
  "headers": {}
}
"""

struct McpView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditTarget?
    @State private var toDelete: MCPServer?
    @State private var toApprove: MCPServer?
    @State private var banner: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("MCP Servers").font(.largeTitle.bold())
                    Spacer()
                    Button { Task { await model.refreshMCP() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button {
                        if let p = model.mcpDirectory { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                    } label: { Label("Reveal folder", systemImage: "folder") }.disabled(model.mcpDirectory == nil)
                    Button { editing = EditTarget(name: "", text: stdioTemplate, isNew: true) } label: { Label("Add server", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
                Text("Each server is its own JSON file. You can add one here or drop a file into the folder and press Reload. Nothing runs until you review and approve it, and editing a server's command or URL asks for approval again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let p = model.mcpDirectory { Text(p).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled) }
                if let b = banner { ErrorStrip(text: b) }

                if model.mcpServers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No MCP servers yet").font(.headline)
                        Text("Press “Add server” and paste a server's JSON (a single server, or a whole {\"mcpServers\": …} block, which gets split into one file each).")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(32)
                }
                ForEach(model.mcpServers) { s in
                    ServerCard(server: s,
                               onEdit: { editing = EditTarget(name: s.name, text: s.configText ?? "", isNew: false) },
                               onDelete: { toDelete = s }, onApprove: { toApprove = s }, onError: { banner = $0 })
                }
            }
            .padding(24).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .task { await model.refreshMCP() }
        .sheet(item: $editing) { t in ServerEditor(target: t) { editing = nil } }
        .alert("Delete \(toDelete?.name ?? "server")?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), presenting: toDelete) { s in
            Button("Delete file", role: .destructive) { Task { banner = await model.deleteMCP(s.name) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("This removes its JSON file and disconnects it.") }
        .alert("Approve and connect \(toApprove?.name ?? "server")?", isPresented: Binding(get: { toApprove != nil }, set: { if !$0 { toApprove = nil } }), presenting: toApprove) { s in
            Button("Approve & connect") { Task { banner = await model.approveAndConnectMCP(s.name) } }
            Button("Cancel", role: .cancel) {}
        } message: { s in
            Text(([s.summary] + s.warnings.map { "⚠︎ \($0)" }).joined(separator: "\n\n"))
        }
    }
}

private struct ServerCard: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer
    let onEdit: () -> Void, onDelete: () -> Void, onApprove: () -> Void
    let onError: (String?) -> Void

    private var status: (String, Color) {
        if server.error != nil { return ("File error", .red) }
        if !server.enabled { return ("Disabled", .secondary) }
        switch server.state {
        case "ready": return ("Connected", .green)
        case "connecting": return ("Connecting…", .yellow)
        case "failed": return ("Failed", .red)
        default: return (server.approved ? "Not connected" : "Needs approval", server.approved ? Color.secondary : Color.orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(server.name).font(.title3.weight(.semibold).monospaced())
                Label(status.0, systemImage: "circle.fill").font(.caption).foregroundStyle(status.1)
                Spacer()
                actions
            }
            if let e = server.error { Text(e).font(.callout).foregroundStyle(Color.red).textSelection(.enabled) }
            else {
                Text(server.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                ForEach(server.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.orange) }
                if !server.envNames.isEmpty { Text("Passes: " + server.envNames.joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary) }
            }
            if let e = server.connectionError { ErrorStrip(text: e) }
            if server.state == "failed", !server.logTail.isEmpty {
                DisclosureGroup("Server log") { Text(server.logTail.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(.caption)
            }
            if server.state == "ready" { toolsList }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if server.error == nil {
                if !server.approved { Button("Review & connect…", action: onApprove).buttonStyle(.borderedProminent) }
                else if server.state == "ready" { Button("Disconnect") { Task { onError(await model.disconnectMCP(server.name)) } } }
                else if server.enabled { Button("Connect") { Task { onError(await model.connectMCP(server.name)) } } }
            }
            Button("Edit", action: onEdit)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Delete this server's file")
        }
    }

    private var toolsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(server.tools.count) tool\(server.tools.count == 1 ? "" : "s")").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(server.tools) { t in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name).font(.callout.monospaced())
                        if !t.description.isEmpty { Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Toggle("Always allow", isOn: Binding(get: { t.trusted }, set: { v in Task { onError(await model.trustMCPTool(server: server.name, tool: t.name, trusted: v)) } }))
                        .toggleStyle(.switch).controlSize(.small).help("Skip the approval prompt for this one tool")
                }
            }
            Text("Tools ask for your approval each time unless you switch on “Always allow” for that tool.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ServerEditor: View {
    @Environment(AppModel.self) private var model
    @State var target: EditTarget
    let close: () -> Void
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.isNew ? "Add MCP server" : "Edit \(target.name)").font(.title2.bold())
            if target.isNew {
                TextField("Name (e.g. filesystem) — not needed if you paste a {\"mcpServers\": …} block", text: $target.name).glassField()
                HStack {
                    Text("Start from:").font(.caption).foregroundStyle(.secondary)
                    Button("Local program") { target.text = stdioTemplate }.buttonStyle(.link)
                    Button("Remote URL") { target.text = remoteTemplate }.buttonStyle(.link)
                }
            }
            TextEditor(text: $target.text).glassEditor(monospaced: true, minHeight: 220)
            if let e = error { Text(e).font(.callout).foregroundStyle(Color.red).textSelection(.enabled) }
            Text("Saved as its own file. Env values and headers are stored in that file, readable only by you.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { Task { await save() } }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(saving || target.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 600)
    }

    private func save() async {
        saving = true; defer { saving = false }
        let name = target.name.trimmingCharacters(in: .whitespaces)
        let err: String?
        if target.isNew { err = await model.importMCP(text: target.text, name: name.isEmpty ? nil : name, overwrite: false) }
        else { err = await model.saveMCP(name: target.name, text: target.text) }
        if let err { error = err } else { close() }
    }
}
