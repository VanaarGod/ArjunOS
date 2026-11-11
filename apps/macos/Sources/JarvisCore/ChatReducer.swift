import Foundation

public enum ChatOutcome: Equatable, Sendable {
    case none
    case failed(String)            // stream-level error to show the user
    case approvalNeeded(String)    // a tool is waiting for the user's decision (approval id)
    case finished
    case thinking                  // the model is reasoning; show "Thinking…" rather than looking frozen
}

/// Pure logic: folds one server event into the assistant message being built. Unit-tested without any UI.
public enum ChatReducer {
    public static func apply(_ ev: ChatEvent, to msg: inout ChatMessage) -> ChatOutcome {
        if let e = ev.error { return .failed("\(e.kind): \(e.message)") }
        if let d = ev.delta, !d.isEmpty { msg.content += d }
        if let t = ev.tool { upsert(toolActivity(t), in: &msg) }
        if let m = ev.memorySaved {
            upsert(MessageActivity(id: "memory-saved-\(m.id)", kind: "memory_saved", title: "Saved to memory", detail: m.content, status: "done", memoryID: m.id), in: &msg)
        }
        if let used = ev.memoryUsed, !used.isEmpty {
            upsert(MessageActivity(id: "memory-used", kind: "memory_used",
                                   title: used.count == 1 ? "Used 1 memory" : "Used \(used.count) memories",
                                   detail: used.map(\.content).joined(separator: "\n"), status: "done"), in: &msg)
        }
        if let files = ev.filesUsed, !files.isEmpty {
            let lines = files.map { f in
                f.excerpted ? "\(f.name) — excerpts: \(f.usedChars.formatted()) of \(f.totalChars.formatted()) characters"
                            : "\(f.name) — read in full (\(f.totalChars.formatted()) characters)"
            }
            upsert(MessageActivity(id: "files-used", kind: "files", title: files.count == 1 ? "Read 1 file" : "Read \(files.count) files",
                                   detail: lines.joined(separator: "\n"), status: "done"), in: &msg)
        }
        if let used = ev.vaultUsed, !used.isEmpty {
            // Merge with notes already listed on this message (automatic context first, then anything the model looked up).
            var links = msg.activity?.first(where: { $0.id == "vault-used" })?.links ?? []
            for u in used where !links.contains(where: { ObsidianLinks.path(fromChipURL: $0.url) == u.path }) {
                links.append(SearchResultItem(title: u.title, url: ObsidianLinks.chipURL(u.path), snippet: [u.heading, u.path].compactMap { $0 }.joined(separator: " · ")))
            }
            upsert(MessageActivity(id: "vault-used", kind: "vault_used", title: links.count == 1 ? "Used 1 note from Obsidian" : "Used \(links.count) notes from Obsidian",
                                   detail: links.map(\.title).joined(separator: ", "), status: "done", links: links), in: &msg)
        }
        if let n = ev.vaultSaved {
            upsert(MessageActivity(id: "vault-saved-\(n.path)", kind: "vault_saved", title: "Saved to Obsidian", detail: n.title, status: "done", path: n.path), in: &msg)
        }
        if let pg = ev.pageUsed {
            let what: String
            if pg.status == "error" || pg.status == "restricted" { what = "couldn't read it" }
            else if pg.excerpted { what = "excerpts: \(pg.usedChars.formatted()) of \(pg.totalChars.formatted()) characters" }
            else { what = "read in full (\(pg.totalChars.formatted()) characters)" }
            var how = pg.source == "ocr" ? " · from a screenshot (OCR)" : (pg.ocr ? " · plus screenshot OCR" : "")
            if pg.structured { how += " · product data" }
            upsert(MessageActivity(id: "page-used", kind: "page", title: pg.status == "ready" || pg.status == "loading" ? "Used the open page" : "Open page",
                                   detail: "\(pg.title.isEmpty ? pg.host : pg.title) · \(pg.host) — \(what)\(how)", status: "done"), in: &msg)
        }
        if let n = ev.notice {
            let count = (msg.activity ?? []).filter { $0.kind == "notice" }.count
            upsert(MessageActivity(id: "notice-\(count)", kind: "notice", title: n), in: &msg)
        }
        if let a = ev.approval { return .approvalNeeded(a.id) }
        if ev.done == true { return .finished }
        if ev.thinking == true { return .thinking }
        return .none
    }

    static func toolActivity(_ t: ToolEvent) -> MessageActivity {
        let id = "tool-\(t.id ?? 0)-\(t.name)"
        if t.name == "web_search" {
            let q = t.query ?? ""
            switch t.status {
            case "running": return MessageActivity(id: id, kind: "search", title: "Searching the web", detail: q, status: "running")
            case "error": return MessageActivity(id: id, kind: "search", title: "Web search failed", detail: t.error ?? q, status: "error")
            default:
                let n = t.results?.count ?? 0
                return MessageActivity(id: id, kind: "search", title: "Searched the web", detail: "\(q) · \(n) result\(n == 1 ? "" : "s")", status: "done", links: t.results ?? [])
            }
        }
        if t.name == "file" {
            let name: String
            if case .string(let n)? = t.args?["name"] { name = n } else { name = "" }
            var path: String? = nil
            if case .string(let p)? = t.args?["path"] { path = p }
            switch t.status {
            case "running": return MessageActivity(id: id, kind: "file", title: "Writing file", detail: name, status: "running")
            case "error": return MessageActivity(id: id, kind: "file", title: "Couldn't create file", detail: name, status: "error", output: t.error)
            default: return MessageActivity(id: id, kind: "file", title: "Created file", detail: name, status: "done", output: t.output, path: path)
            }
        }
        if t.name == "shell" {
            let command: String
            if case .string(let c)? = t.args?["command"] { command = c } else { command = "" }
            let title: String
            switch t.status {
            case "running": title = "Running command"
            case "waiting_approval": title = "Waiting for your approval to run"
            case "error": title = t.exitCode == nil && t.output == nil ? "Command not run" : "Command failed"
            default: title = "Ran command"
            }
            return MessageActivity(id: id, kind: "shell", title: title, detail: command, status: t.status, output: t.output ?? t.error, exitCode: t.exitCode)
        }
        let title: String
        switch t.status {
        case "running": title = "Using \(t.name)"
        case "waiting_approval": title = "Waiting for your approval: \(t.name)"
        case "error": title = "\(t.name) failed"
        default: title = "Used \(t.name)"
        }
        return MessageActivity(id: id, kind: "tool", title: title, detail: t.error, status: t.status)
    }

    static func upsert(_ a: MessageActivity, in msg: inout ChatMessage) {
        var list = msg.activity ?? []
        if let i = list.firstIndex(where: { $0.id == a.id }) { list[i] = a } else { list.append(a) }
        msg.activity = list
    }
}
