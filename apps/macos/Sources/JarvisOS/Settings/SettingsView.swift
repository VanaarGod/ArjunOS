import SwiftUI
import AppKit
import JarvisCore

/// Every settings page. Each feature has its own page; the list on the left jumps between them.
enum SettingsSection: String, CaseIterable, Identifiable {
    case profile, general, floating
    case webSearch, browser, files, terminal
    case memory, obsidian
    case privacy, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Profile"; case .general: "General"; case .floating: "Floating assistant"
        case .webSearch: "Web search"; case .browser: "Browser"; case .files: "Files"; case .terminal: "Terminal"
        case .memory: "Memory"; case .obsidian: "Obsidian"
        case .privacy: "Privacy"; case .diagnostics: "Diagnostics"
        }
    }
    var subtitle: String {
        switch self {
        case .profile: "Who you are and how you like answers. Used as context in every chat."
        case .general: "Name your assistant."
        case .floating: "The pet and the mini chat that float above your other windows."
        case .webSearch: "When ArjunOS may look things up online, and how much."
        case .browser: "Let your local model read the page you have open."
        case .files: "Create files, and let the model read any file or folder you attach or name."
        case .terminal: "Run a few safe commands, only after you approve each one."
        case .memory: "Notes ArjunOS keeps about you and uses in answers."
        case .obsidian: "Connect a vault so the model can search and add notes."
        case .privacy: "Keep everything on this Mac."
        case .diagnostics: "The local bridge, your Python setup and where data lives."
        }
    }
    var symbol: String {
        switch self {
        case .profile: "person.crop.circle.fill"; case .general: "slider.horizontal.3"; case .floating: "pawprint.fill"
        case .webSearch: "magnifyingglass"; case .browser: "globe"; case .files: "doc.fill"; case .terminal: "terminal.fill"
        case .memory: "brain"; case .obsidian: "books.vertical.fill"
        case .privacy: "lock.fill"; case .diagnostics: "stethoscope"
        }
    }
    var tint: Color {
        switch self {
        case .profile: .teal; case .general: .gray; case .floating: .pink
        case .webSearch: .blue; case .browser: .cyan; case .files: .orange; case .terminal: .green
        case .memory: .purple; case .obsidian: .indigo
        case .privacy: .mint; case .diagnostics: .red
        }
    }

    /// The headings in the list on the left.
    static let groups: [(title: String, items: [SettingsSection])] = [
        ("Assistant", [.profile, .general, .floating]),
        ("Abilities", [.webSearch, .browser, .files, .terminal]),
        ("Knowledge", [.memory, .obsidian]),
        ("App", [.privacy, .diagnostics]),
    ]
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        HStack(spacing: 0) {
            SettingsList(selection: $m.settingsSection)
                .frame(width: 228)
            Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 14)
            page
                .id(model.settingsSection)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.smooth(duration: 0.2), value: model.settingsSection)
        .onChange(of: m.assistantName) { _, _ in model.saveSettings() }
        .onChange(of: m.offlineMode) { _, _ in model.saveSettings() }
        .onChange(of: m.pythonPath) { _, _ in model.saveSettings() }
        .task { await model.refreshSettings(); await model.refreshHealth(); await model.refreshShell() }
    }

    @ViewBuilder private var page: some View {
        switch model.settingsSection {
        case .profile: ProfileSettingsPage()
        case .general: GeneralSettingsPage()
        case .floating: FloatingSettingsPage()
        case .webSearch: WebSearchSettingsPage()
        case .browser: BrowserSettingsPage()
        case .files: FilesSettingsPage()
        case .terminal: TerminalSettingsPage()
        case .memory: MemorySettingsPage()
        case .obsidian: ObsidianSettingsPage()
        case .privacy: PrivacySettingsPage()
        case .diagnostics: DiagnosticsSettingsPage()
        }
    }
}

/// The list of pages on the left.
private struct SettingsList: View {
    @Binding var selection: SettingsSection
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings").font(.title2.bold()).padding(.horizontal, 12).padding(.bottom, 8)
                ForEach(SettingsSection.groups, id: \.title) { group in
                    Text(group.title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
                    ForEach(group.items) { item in SettingsListRow(section: item, selected: selection == item) { selection = item } }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }
}

private struct SettingsListRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: section.symbol, tint: section.tint, size: 24)
                Text(section.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(selected ? 0.12 : (hovering ? 0.06 : 0)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
