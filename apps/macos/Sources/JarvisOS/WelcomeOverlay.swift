import SwiftUI
import JarvisCore

/// Shown once, before anything else: asks what to call the user. The answer is saved to the profile and becomes the first memory.
/// Nothing is read from macOS: the app only knows what you tell it.
struct WelcomeOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private let maxLength = 40

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().contentShape(Rectangle())            // swallows clicks: answer first
            VStack(spacing: 18) {
                SettingsIconTile(symbol: "hand.wave.fill", tint: Theme.accent, size: 58)
                VStack(spacing: 6) {
                    Text("Welcome to \(model.assistantName)").font(.title.bold())
                    Text("Before we start: what should I call you?").font(.title3).foregroundStyle(.secondary)
                }
                TextField("Your name or nickname", text: $name)
                    .textFieldStyle(.plain).font(.title3).multilineTextAlignment(.center)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.8) : Theme.hairline, lineWidth: focused ? 1.5 : 1))
                    .onSubmit { submit() }
                    .onChange(of: name) { _, new in if new.count > maxLength { name = String(new.prefix(maxLength)) } }
                Text("This becomes my first memory about you. You can change it any time in Settings → Profile, where you can also set your preferences and instructions.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let error { SettingStatus(text: error, kind: .warning) }
                VStack(spacing: 8) {
                    Button { submit() } label: { Text(saving ? "Saving…" : "Continue").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                        .keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || saving)
                    Button("Skip for now") { skip() }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary).disabled(saving)
                }
            }
            .padding(30).frame(width: 440)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !trimmed.isEmpty, !saving else { return }
        save(ProfileUpdate(callMe: trimmed, onboarded: true))
    }
    private func skip() { save(ProfileUpdate(onboarded: true)) }

    private func save(_ update: ProfileUpdate) {
        saving = true; error = nil
        Task {
            let err = await model.saveProfile(update)
            saving = false
            if let err { error = err }                                   // on success `needsWelcome` turns false and this view goes away
        }
    }
}
