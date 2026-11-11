import SwiftUI
import JarvisCore

/// Settings → Profile: who you are, how you like answers, and your own standing instructions (a system prompt).
/// All of it is sent as context with every chat message, so the page shows what it costs and the bridge keeps it small:
/// only filled-in fields are sent, as short lines; there are hard length limits; it goes first in the request so the model engine
/// can reuse it from turn to turn; and it is never stored in your chats or given to Crew workers.
struct ProfileSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var d = UserProfile()
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var status: Status = .idle
    @State private var meterTokens = 0
    @State private var meterChars = 0
    @State private var showSent = false

    private enum Status: Equatable { case idle, saved, error(String) }
    private static let fallbackLimits = ["call_me": 40, "name": 60, "pronouns": 30, "language": 60, "time_zone": 60, "role": 80, "about": 500, "instructions": 1200]
    private func limit(_ key: String) -> Int { model.profile?.limits[key] ?? Self.fallbackLimits[key] ?? 200 }
    private var maxChars: Int { model.profile?.maxChars ?? 1600 }

    var body: some View {
        SettingsPageScaffold(.profile) {
            if case .error(let e) = status { SettingStatus(text: e, kind: .warning) }
            else if status == .saved { SettingStatus(text: "Saved", kind: .good) }

            SettingsGroup("About you", footer: "What you want to be called is also saved as your first memory, so you can see and edit it in Memory.") {
                SettingRow("What should I call you?") { field("Your name or nickname", $d.callMe, 220) }
                SettingRow("Full name", subtitle: "Only if different.") { field("Optional", $d.name, 220) }
                SettingRow("Pronouns") { field("Optional", $d.pronouns, 160) }
                SettingRow("Main language") { field("For example English", $d.language, 160) }
                SettingRow("Time zone") {
                    HStack(spacing: 8) {
                        field("For example America/New_York", $d.timeZone, 190)
                        Button("This Mac’s") { d.timeZone = TimeZone.current.identifier }.buttonStyle(GlassButtonStyle()).controlSize(.small)
                    }
                }
                SettingRow("What you do") { field("For example CS student", $d.role, 220) }
                SettingBlock {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Anything else worth knowing").font(.body)
                        TextEditor(text: $d.about).glassEditor(minHeight: 70)
                        counter(d.about.count, limit("about"))
                    }
                }
            }

            SettingsGroup("How I talk to you", footer: "“No preference” and “Balanced” add nothing to the prompt, so they cost no tokens.") {
                choiceRow("Directness", "directness", $d.directness)
                choiceRow("Formality", "formality", $d.formality)
                choiceRow("Answer length", "length", $d.length)
                choiceRow("Humor", "humor", $d.humor)
                choiceRow("Emojis", "emoji", $d.emoji)
                choiceRow("Feedback", "feedback", $d.feedback)
            }

            SettingsGroup("Your instructions", footer: "Your own system prompt: rules the model should always follow. Keep it short and specific. Every character is sent with every message.") {
                SettingToggleRow(title: "Send my profile to the model", subtitle: "Turn off to keep everything saved here but send nothing.", isOn: $d.include)
                SettingBlock {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $d.instructions).glassEditor(minHeight: 130)
                            .overlay(alignment: .topLeading) {
                                if d.instructions.isEmpty {
                                    Text("For example: Show code before explanations. Ask before making big changes.").foregroundStyle(.tertiary)
                                        .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                                }
                            }
                        counter(d.instructions.count, limit("instructions"))
                    }
                }
            }

            costGroup
        }
        .task { await load() }
        .onChange(of: model.profile?.onboarded) { _, _ in if !loaded { Task { await load() } } }
        .onChange(of: d) { _, _ in clamp(); scheduleSave() }
    }

    // MARK: pieces

    private func field(_ placeholder: String, _ text: Binding<String>, _ width: CGFloat) -> some View {
        TextField(placeholder, text: text).glassField().frame(width: width)
    }

    private func counter(_ n: Int, _ max: Int) -> some View {
        HStack { Spacer(); Text("\(n) / \(max)").font(.caption.monospacedDigit()).foregroundStyle(Double(n) > Double(max) * 0.9 ? Color.orange : Color.secondary) }
    }

    private func choiceRow(_ title: String, _ key: String, _ value: Binding<String>) -> some View {
        var options = [SettingOption(value: "", title: "No preference", subtitle: "Leave it to the model.")]
        options += (model.profile?.choices[key] ?? []).map { SettingOption(value: $0, title: $0.capitalized) }
        return SettingRow(title) { DropdownPicker(options: options, selection: value, minWidth: 150, menuWidth: 240) }
    }

    private var costGroup: some View {
        let fraction = min(1, Double(meterChars) / Double(max(1, maxChars)))
        let color: Color = fraction < 0.5 ? .green : (fraction < 0.85 ? .orange : .red)
        return SettingsGroup("What this costs", footer: "Compact by design. Only filled-in fields are sent, as short lines, under a hard size limit. It goes first in every request, so your model’s engine can reuse the already-processed start instead of re-reading it each turn. It is never added to your saved chats, and Crew workers never receive it.") {
            SettingBlock {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(meterChars == 0 ? "Nothing is sent" : "About \(meterTokens) tokens per message").font(.body)
                        Spacer()
                        Text("\(meterChars) / \(maxChars) characters").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule().fill(color).frame(width: max(meterChars == 0 ? 0 : 6, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 6).animation(.easeOut(duration: 0.2), value: meterChars)
                }
            }
            SettingRow("Show exactly what is sent") {
                Button(showSent ? "Hide" : "Show") { showSent.toggle() }.buttonStyle(GlassButtonStyle()).controlSize(.small)
            }
            if showSent {
                SettingBlock {
                    Text(sentText.isEmpty ? "Nothing. Fill in a field above." : sentText)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(sentText.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sentText: String { d.include ? (model.profile?.compiled ?? "") : "" }

    // MARK: loading and saving

    private func load() async {
        if model.profile == nil { await model.refreshProfile() }
        guard !loaded, let p = model.profile else { return }
        d = p; loaded = true; meterTokens = p.tokens; meterChars = p.include ? p.chars : 0
    }

    /// Never lets a box grow past its limit (a paste is cut off rather than refused later).
    private func clamp() {
        func cut(_ s: inout String, _ key: String) { let m = limit(key); if s.count > m { s = String(s.prefix(m)) } }
        cut(&d.callMe, "call_me"); cut(&d.name, "name"); cut(&d.pronouns, "pronouns"); cut(&d.language, "language")
        cut(&d.timeZone, "time_zone"); cut(&d.role, "role"); cut(&d.about, "about"); cut(&d.instructions, "instructions")
    }

    /// Only the fields that changed, so an unrelated edit never touches (or re-creates) the name memory.
    private func changes() -> ProfileUpdate? {
        guard let b = model.profile else { return nil }
        var u = ProfileUpdate(); var any = false
        if d.callMe != b.callMe { u.callMe = d.callMe; any = true }
        if d.name != b.name { u.name = d.name; any = true }
        if d.pronouns != b.pronouns { u.pronouns = d.pronouns; any = true }
        if d.language != b.language { u.language = d.language; any = true }
        if d.timeZone != b.timeZone { u.timeZone = d.timeZone; any = true }
        if d.role != b.role { u.role = d.role; any = true }
        if d.about != b.about { u.about = d.about; any = true }
        if d.directness != b.directness { u.directness = d.directness; any = true }
        if d.formality != b.formality { u.formality = d.formality; any = true }
        if d.length != b.length { u.length = d.length; any = true }
        if d.humor != b.humor { u.humor = d.humor; any = true }
        if d.emoji != b.emoji { u.emoji = d.emoji; any = true }
        if d.feedback != b.feedback { u.feedback = d.feedback; any = true }
        if d.instructions != b.instructions { u.instructions = d.instructions; any = true }
        if d.include != b.include { u.include = d.include; any = true }
        return any ? u : nil
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)                              // wait until typing pauses
            if Task.isCancelled { return }
            guard let u = changes() else { return }
            if let pv = await model.previewProfile(u) {                                   // what it would cost, and whether it fits, before saving
                meterTokens = pv.tokens; meterChars = d.include ? pv.chars : 0
                if !pv.ok { status = .error(pv.error ?? "That is too long."); return }
            }
            if let err = await model.saveProfile(u) { status = .error(err); return }
            if let p = model.profile { meterTokens = p.tokens; meterChars = p.include ? p.chars : 0 }
            status = .saved
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if status == .saved { status = .idle }
        }
    }
}
