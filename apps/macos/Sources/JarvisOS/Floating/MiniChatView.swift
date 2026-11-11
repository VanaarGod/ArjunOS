import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JarvisCore

/// The floating mini chat. It is another view of the same `AppModel` conversation the main window shows: same messages,
/// model, approvals, attachments and page awareness. Anything said here appears in the main window and vice versa.
struct MiniChatView: View {
    let controller: FloatingAssistantController
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var dropTargeted = false
    @State private var capturing = false
    @State private var captureError: String?

    private var petMode: Bool { controller.settings.displayMode.showsPet }

    var body: some View {
        ZStack {
            VisualEffectBackground()
            RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 360).allowsHitTesting(false)
            VStack(spacing: 0) {
                header
                Divider().opacity(0.25)
                ZStack(alignment: .bottom) {
                    if model.current.messages.isEmpty { emptyState } else { messageList }
                }
                footer
            }
        }
        .environment(\.openURL, OpenURLAction { url in model.openLink(url); return .handled })
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay { if dropTargeted { DropOverlay() } }
        .onExitCommand { controller.setChatOpen(false) }                 // Esc
        .onAppear { focused = true }
        .onChange(of: controller.focusRequest) { _, _ in focused = true }
        .onChange(of: model.isStreaming) { _, now in if !now { focused = true } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AssistantOrb(size: 28, thinking: model.isStreaming)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.assistantName).font(.callout.weight(.semibold))
                Text(model.menuState == .asleep || model.menuState == .idle ? "Ready" : model.menuState.label).font(.caption2).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            Spacer()
            if controller.settings.displayMode == .petOnly {
                headerButton(controller.chatPinned ? "pin.fill" : "pin", help: controller.chatPinned ? "Unpin: close when you click away" : "Pin: keep open when you click away") { controller.chatPinned.toggle() }
            }
            headerButton("square.and.pencil", help: "New chat") { model.newConversation() }
            headerButton("macwindow", help: "Open in \(model.assistantName)") { controller.openMainWindow(section: .chat) }
            headerButton(petMode ? "chevron.down" : "xmark", help: petMode ? "Collapse to the pet (Esc)" : "Hide the chat (Esc, or \(controller.settings.hotKey.display))") { controller.setChatOpen(false) }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .animation(Theme.smooth, value: model.menuState)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.secondary).hoverFill(cornerRadius: 8).help(help)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.current.messages) { m in
                        MessageRow(message: m, name: model.assistantName, streaming: model.isStreaming && m.id == model.current.messages.last?.id).id(m.id)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .onChange(of: model.current.messages.last?.content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.current.messages.last?.activity?.count) { _, _ in withAnimation(Theme.smooth) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.current.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            AssistantOrb(size: 48, thinking: model.isStreaming)
            Text("How can I help?").font(.title3)
            Text(model.selectedModelShortName.map { "\(model.assistantName) · \($0)" } ?? "No model connected yet")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).padding(.horizontal, 20)
            HStack(spacing: 8) {
                starter("Summarize this page", "doc.text.magnifyingglass", "Summarize the page I have open.")
                starter("Search the web", "globe", "Search the web for ")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func starter(_ title: String, _ icon: String, _ prompt: String) -> some View {
        Button { draft = prompt; focused = true } label: { Label(title, systemImage: icon).font(.caption) }.buttonStyle(GlassButtonStyle())
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let e = captureError { ErrorStrip(text: e).transition(.opacity) }
            if let e = model.streamError { ErrorStrip(text: e).transition(.opacity) }
            ApprovalBanner()
            if let hint = model.connectionHint { Label(hint, systemImage: "bolt.horizontal.circle").font(.caption).foregroundStyle(.secondary) }
            PageChip()
            composer
        }
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 6)
        .animation(Theme.smooth, value: model.approvals.count)
        .animation(Theme.smooth, value: model.streamError)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.drafts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(model.drafts) { DraftChip(draft: $0) } } }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    controller.suppressDismiss = true
                    FilePicker.pick(into: model)
                    controller.suppressDismiss = false
                    controller.focusChat()
                } label: { Image(systemName: "paperclip").frame(width: 26, height: 26).contentShape(Circle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Attach files")
                TextField(model.drafts.isEmpty ? "Ask anything…" : "Ask about the attached file…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5).focused($focused).onSubmit(send)
                    .padding(.vertical, 4)
                sendButton
            }
            HStack(spacing: 8) {
                ModelMenu().font(.caption)
                screenToggle
                if model.current.temporary { Label("Temporary", systemImage: "eye.slash").font(.caption2).foregroundStyle(.orange) }
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { ThinkingGlow(active: model.isStreaming, cornerRadius: 20) }
    }

    /// Eye button: when on, each message you send from here includes a capture of the window behind ArjunOS.
    private var screenToggle: some View {
        let on = controller.settings.shareScreen
        return Button { controller.setShareScreen(!on); captureError = nil } label: {
            HStack(spacing: 5) {
                if capturing { ProgressView().controlSize(.mini) } else { Image(systemName: on ? "eye.fill" : "eye.slash") }
                Text(on ? "Seeing screen" : "Screen off")
            }
            .font(.caption).foregroundStyle(on ? Theme.accent : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((on ? Theme.accent.opacity(0.18) : Color.white.opacity(0.05)), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "Each message includes the window behind \(model.assistantName). Click to turn off." : "Click to let \(model.assistantName) see the window behind it when you send a message.")
    }

    @ViewBuilder private var sendButton: some View {
        if model.isStreaming {
            Button { model.stopStreaming() } label: { Image(systemName: "stop.fill").foregroundStyle(.white) }
                .buttonStyle(GlassCircleButtonStyle(tint: Color.red.opacity(0.7), size: 28)).help("Stop (⌘.)")
        } else {
            let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isReadingFiles || capturing
            Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                .buttonStyle(GlassCircleButtonStyle(tint: empty ? nil : Theme.accent.opacity(0.8), size: 28)).disabled(empty).help("Send (Return)")
        }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !model.isStreaming, !model.isReadingFiles, !capturing else { return }
        captureError = nil
        guard controller.settings.shareScreen else { draft = ""; model.send(t); return }
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            do {
                let shot = try await ScreenCapture.captureWindowBehindUs()
                draft = ""
                model.send(t, extraAttachments: [Attachment(name: shot.name, kind: "image", bytes: shot.bytes, imageBase64: shot.jpegBase64)])
            } catch {
                captureError = error.localizedDescription          // keep the typed text so nothing is lost; the user can retry or turn the screen off
            }
        }
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
}

/// Dark blurred window material that stays active even when ArjunOS is not the frontmost app.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
