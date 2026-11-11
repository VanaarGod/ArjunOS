import SwiftUI
import AppKit
import JarvisCore

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showMore = false
    @Namespace private var pill

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchPill.padding(.top, 34).padding(.bottom, 6)
            NavRow(ns: pill, symbol: NavSection.chat.symbol, title: "New chat", selected: model.selection == .chat && model.currentIsEmpty) { model.newConversation() }
            NavRow(ns: pill, symbol: "globe", title: "Browser", selected: false, badge: model.browser.isOpen ? "open" : nil) { model.browser.toggle() }
            NavRow(ns: pill, symbol: NavSection.crew.symbol, title: "Crew", selected: model.selection == .crew) { model.selection = .crew }
            NavRow(ns: pill, symbol: NavSection.models.symbol, title: "Models", selected: model.selection == .models) { model.selection = .models }
            NavRow(ns: pill, symbol: NavSection.tools.symbol, title: "MCP Servers", selected: model.selection == .tools) { model.selection = .tools }
            NavRow(ns: pill, symbol: NavSection.memory.symbol, title: "Memory", selected: model.selection == .memory) { model.selection = .memory }
            NavRow(ns: pill, symbol: NavSection.voice.symbol, title: "Voice", selected: model.selection == .voice, badge: "soon") { model.selection = .voice }
            DisclosureGroup(isExpanded: $showMore) {
                NavRow(ns: pill, symbol: NavSection.knowledge.symbol, title: "Knowledge", selected: model.selection == .knowledge, badge: model.vault.active ? "Obsidian" : nil) { model.selection = .knowledge }
                NavRow(ns: pill, symbol: NavSection.tasks.symbol, title: "Tasks", selected: model.selection == .tasks, badge: model.approvals.isEmpty ? nil : "\(model.approvals.count)") { model.selection = .tasks }
                NavRow(ns: pill, symbol: NavSection.system.symbol, title: "System", selected: model.selection == .system) { model.selection = .system }
            } label: {
                Label("More", systemImage: showMore ? "chevron.up" : "chevron.down").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .overlay(alignment: .trailing) {
                if !showMore && !model.approvals.isEmpty { Circle().fill(.orange).frame(width: 8, height: 8).padding(.trailing, 28) }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.day) { g in
                        Text(title(for: g.day)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                        ForEach(g.items) { c in HistoryRow(conversation: c).transition(.opacity.combined(with: .move(edge: .leading))) }
                    }
                    if model.conversations.isEmpty {
                        Text("Your conversations will appear here.").font(.caption).foregroundStyle(.tertiary).padding(12)
                    } else if model.filteredConversations.isEmpty {
                        Text("No matches.").font(.caption).foregroundStyle(.tertiary).padding(12)
                    }
                }
                .animation(Theme.smooth, value: model.conversations.count)
            }.scrollIndicators(.hidden)

            footer
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
        .animation(Theme.snappy, value: model.selection)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search chats", text: Bindable(model).searchText).textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { model.settingsSection = .profile; model.selection = .settings } label: {
                HStack(spacing: 10) {
                    ZStack { Circle().fill(Theme.accent.opacity(0.25)); Text(String(model.userLabel.prefix(1)).uppercased()).font(.callout.bold()) }
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.userLabel).font(.callout).lineLimit(1)
                        BridgeBadge()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Your profile")
            Spacer()
            Button { model.selection = .settings } label: { Image(systemName: "gearshape").foregroundStyle(model.selection == .settings ? Color.white : Color.secondary) }
                .buttonStyle(.plain).help("Settings")
        }.padding(.horizontal, 8).padding(.top, 8)
    }

    private struct Group_: Identifiable { var day: Date; var items: [Conversation]; var id: Date { day } }
    private var groups: [Group_] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: model.filteredConversations) { cal.startOfDay(for: $0.updatedAt) }
        return dict.keys.sorted(by: >).map { Group_(day: $0, items: dict[$0]!.sorted { $0.updatedAt > $1.updatedAt }) }
    }
    private func title(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct NavRow: View {
    let ns: Namespace.ID
    let symbol: String, title: String
    var selected: Bool
    var badge: String? = nil
    let action: () -> Void
    @State private var pressed = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).lineLimit(1)
                Spacer()
                if let badge {
                    Text(badge).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.10), in: Capsule()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                        .matchedGeometryEffect(id: "navpill", in: ns)      // the highlight slides between rows
                }
            }
            .hoverFill(cornerRadius: 12, strength: selected ? 0 : 0.06)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    var body: some View {
        Button { model.select(conversation) } label: {
            HStack(spacing: 10) {
                Image(systemName: "circle").font(.system(size: 6)).foregroundStyle(.secondary)
                Text(conversation.title).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(model.currentID == conversation.id && model.selection == .chat ? Color.white.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .hoverFill(cornerRadius: 10, strength: 0.05)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Export as Markdown…") { export() }
            Button("Delete", role: .destructive) { model.deleteConversation(conversation) }
        }
    }
    private func export() {
        let p = NSSavePanel(); p.nameFieldStringValue = "\(conversation.title).md"
        if p.runModal() == .OK, let u = p.url { try? ConversationStore.exportMarkdown(model.fullConversation(conversation)).write(to: u, atomically: true, encoding: .utf8) }
    }
}
