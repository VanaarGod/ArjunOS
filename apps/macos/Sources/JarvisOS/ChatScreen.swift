import SwiftUI
import UniformTypeIdentifiers
import AppKit
import JarvisCore

struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var dropTargeted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.current.messages.isEmpty { emptyState } else { messageList }
            VStack(spacing: 8) {
                if let e = model.streamError { ErrorStrip(text: e).transition(.move(edge: .bottom).combined(with: .opacity)) }
                ApprovalBanner()
                if model.needsSearchConsent { ConsentBanner().transition(.move(edge: .bottom).combined(with: .opacity)) }
                if let hint = model.connectionHint {
                    Label(hint, systemImage: "bolt.horizontal.circle").font(.callout).foregroundStyle(.secondary).transition(.opacity)
                }
                PageChip()
                Composer(draft: $draft, focused: $focused, onSend: send)
            }
            .animation(Theme.smooth, value: model.approvals.count)
            .animation(Theme.smooth, value: model.streamError)
            .animation(Theme.smooth, value: model.needsSearchConsent)
            .frame(maxWidth: 780)
            .padding(.horizontal, 40).padding(.bottom, 22)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay { if dropTargeted { DropOverlay() } }
        .onAppear { focused = true }
        .onChange(of: model.current.id) { _, _ in focused = true }
        .onChange(of: model.isStreaming) { _, now in if !now { focused = true } }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) } else if let u = item as? URL { url = u }
                if let url { Task { @MainActor in model.addFiles([url]) } }
            }
        }
        return accepted
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !model.isStreaming, !model.isReadingFiles else { return }
        draft = ""
        model.send(t)
    }

    private var emptyState: some View {
        ZStack(alignment: .top) {
            BinaryField().frame(height: 250).frame(maxWidth: .infinity).mask(
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 18) {
                AssistantOrb(size: 64, thinking: model.isStreaming).staggerIn(0)
                Text(greeting).font(.system(size: 34, weight: .regular)).staggerIn(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).padding(.horizontal, 40).staggerIn(2)
                GlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(Array(starters.enumerated()), id: \.element.id) { i, s in
                            Button { draft = s.prompt; focused = true } label: { Label(s.title, systemImage: s.icon) }
                                .buttonStyle(GlassButtonStyle()).staggerIn(3 + i)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 120)
        }
    }

    private struct Starter: Identifiable { let id: String; let icon: String; let prompt: String; var title: String { id } }
    private var starters: [Starter] {
        [Starter(id: "Create a file", icon: "doc.badge.plus", prompt: "Create a markdown file about "),
         Starter(id: "Write some code", icon: "chevron.left.forwardslash.chevron.right", prompt: "Write a JavaScript file that "),
         Starter(id: "Search the web", icon: "globe", prompt: "Search the web for ")]
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"; case 12..<17: "Good afternoon"; case 17..<22: "Good evening"; default: "Hello"
        }
    }
    private var subtitle: String {
        if let m = model.selectedModelShortName { return "\(model.assistantName) is ready · \(m)" }
        return "\(model.assistantName) · no model connected yet"
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.current.messages) { m in
                        MessageRow(message: m, name: model.assistantName, streaming: model.isStreaming && m.id == model.current.messages.last?.id)
                            .id(m.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .bottom)),
                                                    removal: .opacity))
                    }
                    Color.clear.frame(height: 150).id("bottom")
                }
                .frame(maxWidth: 780).padding(.horizontal, 40).padding(.top, 44)
                .frame(maxWidth: .infinity)
                .animation(Theme.gentle, value: model.current.messages.count)
            }
            .onChange(of: model.current.messages.last?.content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.current.messages.last?.activity?.count) { _, _ in withAnimation(Theme.smooth) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.current.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage, name: String
    var streaming: Bool = false
    var body: some View {
        if message.role == "user" {
            VStack(alignment: .trailing, spacing: 8) {
                if let files = message.attachments, !files.isEmpty { AttachmentChips(attachments: files) }
                HStack { Spacer(minLength: 80)
                    Text(message.content).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: Theme.accent.opacity(0.35))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(name)\(message.model.map { " · \(AppModel.shortModelName($0))" } ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let acts = message.activity, !acts.isEmpty { ActivityList(activities: acts) }
                if message.content.isEmpty && streaming && (message.activity ?? []).allSatisfy({ $0.status != "waiting_approval" }) {
                    TypingDots()
                } else if !message.content.isEmpty {
                    RichText(key: message.id.uuidString, markdown: message.content)
                    if !streaming { MessageActions(text: message.content) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Small action row under a finished answer.
struct MessageActions: View {
    let text: String
    @State private var copied = false
    var body: some View {
        HStack(spacing: 14) {
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain).help("Copy the answer as markdown")
            .animation(Theme.snappy, value: copied)
        }
    }
}

struct TypingDots: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            dots
            if model.modelThinking { Text("Thinking…").font(.callout).foregroundStyle(.secondary).transition(.opacity.combined(with: .move(edge: .leading))) }
        }
        .animation(Theme.smooth, value: model.modelThinking)
    }

    @ViewBuilder private var dots: some View {
        if reduceMotion { Text("thinking…").foregroundStyle(.secondary) }
        else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * 5
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        let wave = (sin(t - Double(i) * 0.9) + 1) / 2          // 0...1, each dot a little behind the last
                        Circle().fill(Theme.accent.opacity(0.35 + 0.65 * wave)).frame(width: 7, height: 7).offset(y: -3 * wave)
                    }
                }
            }.accessibilityLabel("Thinking")
        }
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.drafts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(model.drafts) { DraftChip(draft: $0) } } }
            }
            TextField(model.drafts.isEmpty ? "Ask anything…" : "Ask about the attached file…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...8)
                .focused(focused)
                .onSubmit(onSend)                      // Return sends
                .frame(minHeight: 44, alignment: .topLeading)
            HStack(spacing: 10) {
                Menu {
                    Button("Attach files…") { FilePicker.pick(into: model) }
                    Divider()
                    Button("New chat") { model.newConversation() }
                    Button("New temporary chat (never saved)") { model.newConversation(temporary: true) }
                } label: { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Circle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Divider().frame(height: 18)
                ModelMenu()
                Divider().frame(height: 18)
                Label("Ask before acting", systemImage: "hand.raised").font(.callout).foregroundStyle(.secondary)
                    .help("Every consequential action needs your approval. Approvals appear under Tasks.")
                if model.current.temporary { Label("Temporary", systemImage: "eye.slash").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button {} label: { Image(systemName: "mic").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).disabled(true).help("Voice input isn't implemented yet")
                sendButton
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
        .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { ThinkingGlow(active: model.isStreaming, cornerRadius: 26) }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(focused.wrappedValue && !model.isStreaming ? 0.22 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.2), value: focused.wrappedValue)
    }

    @ViewBuilder private var sendButton: some View {
        if model.isStreaming {
            Button { model.stopStreaming() } label: { Image(systemName: "stop.fill").foregroundStyle(.white).contentTransition(.symbolEffect(.replace)) }
                .buttonStyle(GlassCircleButtonStyle(tint: Color.red.opacity(0.7)))
                .keyboardShortcut(".", modifiers: .command).help("Stop (⌘.)")
        } else {
            let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isReadingFiles
            Button(action: onSend) { Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white).contentTransition(.symbolEffect(.replace)) }
                .buttonStyle(GlassCircleButtonStyle(tint: empty ? nil : Theme.accent.opacity(0.8)))
                .disabled(empty).help("Send (Return)")
                .animation(Theme.snappy, value: empty)
        }
    }
}

/// Model picker. Lists what discovery actually found; never invents entries.
struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Menu {
            if model.chatModels.isEmpty { Text("No models detected") }
            ForEach(Array(Dictionary(grouping: model.chatModels, by: \.endpoint).keys.sorted()), id: \.self) { ep in
                Section(providerLabel(ep)) {
                    ForEach(model.chatModels.filter { $0.endpoint == ep }) { m in
                        Button {
                            model.selectModel("\(m.endpoint)|\(m.modelID ?? "")")
                        } label: {
                            if model.selectedModelKey == "\(m.endpoint)|\(m.modelID ?? "")" { Label(AppModel.shortModelName(m.modelID ?? ""), systemImage: "checkmark") }
                            else { Text(AppModel.shortModelName(m.modelID ?? "")) }
                        }
                    }
                }
            }
            Divider()
            Button("Rescan for models") { Task { await model.rescan() } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Text(model.selectedModelShortName ?? "No model").lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260, alignment: .leading)          // a very long model name must never widen the composer
            .help(model.selectedModelName ?? "")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
    private func providerLabel(_ key: String) -> String {
        let p = model.providers.first { $0.key == key }
        return "\(p.map { $0.kind == "ollama" ? "Ollama" : $0.kind } ?? "Provider") · \(key)"
    }
}
