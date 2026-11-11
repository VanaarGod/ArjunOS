import SwiftUI
import AppKit
import JarvisCore

// MARK: - General

struct GeneralSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    var body: some View {
        SettingsPageScaffold(.general) {
            SettingsGroup("Assistant", footer: "The name appears in chat, in the menu bar and in the floating assistant. Leave it empty to use ArjunOS.") {
                SettingRow("Display name") { TextField("ArjunOS", text: $draft).glassField().frame(width: 240) }
            }
        }
        .onAppear { draft = model.assistantName }
        .onChange(of: draft) { _, new in
            let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
            model.assistantName = t.isEmpty ? "ArjunOS" : t          // never empty, so the app never shows a blank name
        }
    }
}

// MARK: - Web search

struct WebSearchSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var testing = false
    @State private var testOutput: String?
    @State private var testFailed = false

    var body: some View {
        let consented = model.settings?.webSearchConsented == true
        SettingsPageScaffold(.webSearch) {
            SettingsGroup(footer: model.offlineMode ? "Offline mode is on, so web search is disabled."
                          : "Only the short search query, never your conversation, is sent to DuckDuckGo. Every search is shown in the chat.") {
                SettingToggleRow(title: "Allow web search", subtitle: "Needed before ArjunOS can search at all.",
                                 isOn: Binding(get: { model.settings?.webSearchConsented ?? false }, set: { v in Task { await model.updateSettings(consent: v) } }))
                    .disabled(model.offlineMode || model.settings == nil)
                SettingRow("When to search") {
                    DropdownPicker(options: [
                        SettingOption(value: "auto", title: "Automatic", subtitle: "Whenever a question needs current information."),
                        SettingOption(value: "keyword", title: "When I ask", subtitle: "Only when I say “search …”, “look up …” or “google …”."),
                        SettingOption(value: "off", title: "Never", subtitle: "Keep the permission but do not search."),
                    ], selection: Binding(get: { model.settings?.webSearchMode ?? "auto" }, set: { v in Task { await model.updateSettings(mode: v) } }))
                }
                .disabled(!consented)
                SettingRow("Results per search") {
                    NumberStepper(value: Binding(get: { model.settings?.webSearchMaxResults ?? 5 }, set: { v in Task { await model.updateSettings(maxResults: v) } }), range: 1...10)
                }
                .disabled(!consented)
            }
            SettingsGroup("Check it works") {
                SettingRow("Test web search", subtitle: testOutput) {
                    Button(testing ? "Testing…" : "Run test") { runTest() }.buttonStyle(GlassButtonStyle()).disabled(testing || !consented)
                }
            }
            if let t = testOutput { SettingStatus(text: t, kind: testFailed ? .warning : .good) }
        }
    }

    private func runTest() {
        testing = true; testOutput = nil
        Task {
            switch await model.testWebSearch() {
            case .success(let r): testFailed = r.isEmpty; testOutput = r.isEmpty ? "Reached DuckDuckGo but got no results." : "Works: \(r.count) results, e.g. “\(r[0].title)”"
            case .failure(let e): testFailed = true; testOutput = e.localizedDescription
            }
            testing = false
        }
    }
}

// MARK: - Browser

struct BrowserSettingsPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let chars = model.settings?.pageContextChars ?? 16000
        SettingsPageScaffold(.browser) {
            SettingsGroup("Reading pages", footer: "The open page is read when you send a message and given to your local model as the main source. It never leaves this Mac. Passwords and form fields are never read, sign-in pages are withheld, and while a page is in context the terminal and external tools are switched off, so a web page can't give them instructions.") {
                SettingToggleRow(title: "Read the page I have open", subtitle: "When I ask about it, \(model.assistantName) can see the current page.",
                                 isOn: Binding(get: { model.settings?.browserEnabled ?? true }, set: { v in Task { await model.updateSettings(browser: v) } }))
                    .disabled(model.settings == nil)
                SettingRow("Page text given to the model") {
                    DropdownPicker(options: characterOptions([(8000, "Small"), (16000, "Standard"), (32000, "Large"), (60000, "Maximum")], current: chars),
                                   selection: Binding(get: { chars }, set: { v in Task { await model.updateSettings(pageChars: v) } }))
                }
                .disabled(model.settings == nil)
                SettingToggleRow(title: "Also read a screenshot (OCR)", subtitle: "Adds text from images on the page to every message.",
                                 isOn: Binding(get: { model.browser.alwaysOCR }, set: { model.browser.setAlwaysOCR($0) }))
            }
            SettingsGroup("Links and data") {
                SettingToggleRow(title: "Open chat links in the built-in browser", isOn: Binding(get: { model.openLinksInBrowser }, set: { model.setOpenLinksInBrowser($0) }))
                SettingRow("Browsing data", subtitle: "Cookies, history and site data from the built-in browser.") {
                    Button("Clear…") { Task { await model.browser.clearBrowsingData() } }.buttonStyle(GlassButtonStyle())
                }
            }
        }
    }
}

// MARK: - Files

struct FilesSettingsPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let chars = model.settings?.attachmentContextChars ?? 12000
        SettingsPageScaffold(.files) {
            SettingsGroup("Creating files", footer: "Files are saved in the workspace folder, never overwrite anything (a number is added instead), and only plain-text types like .md, .txt, .js, .json, .html, .css, .csv and .py are allowed. Nothing is run.") {
                SettingToggleRow(title: "Create files when I ask", subtitle: "For example “create a markdown file about cats”.",
                                 isOn: Binding(get: { model.settings?.filesEnabled ?? true }, set: { v in Task { await model.updateSettings(files: v) } }))
                    .disabled(model.settings == nil)
                if let t = model.shellStatus {
                    SettingRow("Workspace folder", subtitle: t.workspace.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        Button("Show") { NSWorkspace.shared.open(URL(fileURLWithPath: t.workspace)) }.buttonStyle(GlassButtonStyle())
                    }
                }
            }
            SettingsGroup("Files you name", footer: "Write a path in a message, like “summarise ~/Documents/budget.xlsx”, and that file (or folder) is read and given to the model. Every type works: text and code, PDF, Word, Excel, PowerPoint, OpenDocument, RTF, EPUB, databases, archives, images (for vision models) and anything else (what it is, plus any readable text inside). Only paths you type are read, never ones found in a web page or file, and you are told exactly what was read. Keys, keychains, cloud and browser logins are never read. The first time, macOS may ask permission to open Documents, Desktop or Downloads.") {
                SettingToggleRow(title: "Read files I mention by path", subtitle: "Turn off to only use files you attach.",
                                 isOn: Binding(get: { model.settings?.readPaths ?? true }, set: { v in Task { await model.updateSettings(readPaths: v) } }))
                    .disabled(model.settings == nil)
            }
            SettingsGroup("Attached files", footer: "Bigger files are shortened to the parts most relevant to your question, and the chat tells you how much was read. Local models have limited memory: if answers seem to ignore your file, choose a smaller size or a model with a larger context window.") {
                SettingRow("Text read per answer") {
                    DropdownPicker(options: characterOptions([(6000, "Small"), (12000, "Standard"), (24000, "Large"), (48000, "Very large")], current: chars),
                                   selection: Binding(get: { chars }, set: { v in Task { await model.updateSettings(attachmentChars: v) } }))
                }
            }
        }
    }
}

// MARK: - Terminal

struct TerminalSettingsPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsPageScaffold(.terminal) {
            SettingsGroup(footer: "Every command asks for your approval first. Commands run in their own workspace folder, with no network, and the sandbox stops them from deleting files or starting other programs. JavaScript can still overwrite files inside that folder.") {
                SettingToggleRow(title: "Run commands in a sandbox", subtitle: "\(model.assistantName) can propose commands; nothing runs until you approve it.",
                                 isOn: Binding(get: { model.settings?.shellEnabled ?? true }, set: { v in Task { await model.updateSettings(shell: v) } }))
                    .disabled(model.settings == nil)
            }
            if let t = model.shellStatus {
                SettingsGroup("Sandbox") {
                    SettingBlock {
                        SettingStatus(text: t.javascriptReady ? "JavaScript (Node) ready"
                                      : (t.node == nil ? "Node.js not found. Install it from nodejs.org or with `brew install node`." : "JavaScript disabled: no OS sandbox available."),
                                      kind: t.javascriptReady ? .good : .warning)
                    }
                    SettingRow("Allowed commands", subtitle: t.allowed.joined(separator: ", ") + ". Never allowed: sudo, rm and any other way to delete files, pipes, network.") {}
                    SettingRow("Workspace folder", subtitle: t.workspace.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        Button("Show") { NSWorkspace.shared.open(URL(fileURLWithPath: t.workspace)) }.buttonStyle(GlassButtonStyle())
                    }
                    SettingRow("Test the sandbox", subtitle: "Tries to break out and shows what was blocked. Run it once.") {
                        Button(model.sandboxTesting ? "Testing…" : "Run test") { Task { await model.runSandboxSelfTest() } }
                            .buttonStyle(GlassButtonStyle()).disabled(model.sandboxTesting)
                    }
                }
                if let r = model.sandboxTest {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(r.checks.enumerated()), id: \.element.id) { i, c in
                            SettingStatus(text: "\(c.name): \(c.detail)", kind: c.ok ? .good : .bad).staggerIn(i)
                        }
                        Text(r.ok ? "The sandbox blocked everything it should." : "Not every check passed. Turn the terminal off until this is fixed.")
                            .font(.caption.weight(.semibold)).foregroundStyle(r.ok ? Color.green : Color.red)
                    }
                    .padding(.horizontal, 6).transition(.opacity)
                }
            }
        }
    }
}

// MARK: - Memory

struct MemorySettingsPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsPageScaffold(.memory) {
            SettingsGroup(footer: "Say “remember …” in chat to save a note. Secrets such as API keys are never saved.") {
                SettingToggleRow(title: "Use saved memories in answers", subtitle: "Relevant notes are offered to the model automatically.",
                                 isOn: Binding(get: { model.settings?.memoryAutoInject ?? true }, set: { v in Task { await model.updateSettings(inject: v) } }))
                SettingRow("Review or delete notes") {
                    Button("Open Memory") { model.selection = .memory }.buttonStyle(GlassButtonStyle())
                }
            }
        }
    }
}

// MARK: - Obsidian

struct ObsidianSettingsPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let vault = model.vault, s = vault.status, cfg = model.settings
        let on = cfg?.obsidianEnabled ?? false
        SettingsPageScaffold(.obsidian) {
            SettingsGroup("Vault") {
                SettingToggleRow(title: "Use an Obsidian vault", isOn: Binding(get: { on }, set: { v in
                    if v && !vault.configured { vault.chooseFolder() } else { Task { await vault.set(enabled: v) } }
                }))
                if vault.configured {
                    SettingRow("Folder", subtitle: s?.issue == nil && s?.active == true ? "\(s?.notes ?? 0) notes indexed." : nil) {
                        HStack(spacing: 10) {
                            Text(s?.vaultName ?? URL(fileURLWithPath: cfg?.obsidianVaultPath ?? "").lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                            Button("Change…") { vault.chooseFolder() }.buttonStyle(GlassButtonStyle())
                        }
                    }
                }
                if let issue = s?.issue { SettingBlock { SettingStatus(text: issue, kind: .warning) } }
                if let e = vault.error { SettingBlock { SettingStatus(text: e, kind: .warning) } }
            }
            SettingsGroup("What the model may do",
                          footer: "The model can always search and read your vault when it is connected. It never edits your own notes: new notes go in the “\(cfg?.obsidianAgentFolder ?? "ArjunOS")” folder, and it only adds to notes it created. With a web page open it cannot write notes at all. Memories are mirrored as notes in \(s?.memoriesFolder ?? "ArjunOS/Memories"); sensitive ones and anything that looks like a secret are never copied there.") {
                SettingToggleRow(title: "Give the model matching notes", subtitle: "Notes that match your question are added to the conversation.",
                                 isOn: Binding(get: { cfg?.obsidianAutoContext ?? true }, set: { v in Task { await vault.set(autoContext: v) } }))
                SettingToggleRow(title: "Store memories in the vault",
                                 isOn: Binding(get: { cfg?.obsidianStoreMemories ?? true }, set: { v in Task { await vault.set(storeMemories: v) } }))
                SettingToggleRow(title: "Let the model create new notes",
                                 isOn: Binding(get: { cfg?.obsidianAllowWrite ?? true }, set: { v in Task { await vault.set(allowWrite: v) } }))
            }
            .disabled(!on)
        }
        .task { model.vault.attach(model); await model.vault.refresh() }
    }
}

// MARK: - Privacy

struct PrivacySettingsPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var m = model
        SettingsPageScaffold(.privacy) {
            SettingsGroup(footer: "Applies when the bridge restarts. Nothing leaves your Mac except web searches you've allowed.") {
                SettingToggleRow(title: "Offline mode", subtitle: "The bridge refuses every endpoint that is not on this Mac.", isOn: $m.offlineMode)
            }
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettingsPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var m = model
        SettingsPageScaffold(.diagnostics) {
            SettingsGroup("Bridge") {
                SettingRow("Status") {
                    HStack(spacing: 12) {
                        BridgeBadge()
                        Button("Restart") { Task { await model.restartBridge() } }.buttonStyle(GlassButtonStyle())
                    }
                }
                SettingRow("Python for the bridge") { TextField("", text: $m.pythonPath).glassField().frame(width: 320) }
                if let h = model.health {
                    SettingBlock {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingStatus(text: h.pdfSupport == false ? "PDF reading unavailable. Run scripts/setup.sh, then restart the bridge."
                                          : (h.pdfSupport == true ? "PDF reading ready" : "PDF reading unknown"),
                                          kind: h.pdfSupport == true ? .good : .warning)
                            if let py = h.python { Text("Bridge Python: \(py)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }
            }
            SettingsGroup("Data") {
                SettingRow("State folder", subtitle: AppModel.supportDir.appendingPathComponent("state").path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Button("Show") { NSWorkspace.shared.open(AppModel.supportDir.appendingPathComponent("state")) }.buttonStyle(GlassButtonStyle())
                }
            }
        }
    }
}
