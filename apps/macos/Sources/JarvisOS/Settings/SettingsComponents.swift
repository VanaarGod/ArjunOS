import SwiftUI
import AppKit

// Building blocks for the Settings pages. Every page is made from the same few pieces so the whole
// area looks and behaves the same way: a header, grouped cards, rows, switches, and one dropdown style.

// MARK: - Page scaffold

/// The title block and scrolling container shared by every settings page.
struct SettingsPageScaffold<Content: View>: View {
    let section: SettingsSection
    private let content: Content
    init(_ section: SettingsSection, @ViewBuilder content: () -> Content) { self.section = section; self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    SettingsIconTile(symbol: section.symbol, tint: section.tint, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title).font(.title.bold())
                        Text(section.subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 2)
                content
            }
            .padding(.horizontal, 32).padding(.vertical, 26)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}

/// A small rounded square with a symbol in it. Used in the page header and in the settings list.
struct SettingsIconTile: View {
    let symbol: String, tint: Color, size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.62)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
    }
}

// MARK: - Groups and rows

/// A titled card that holds a stack of rows, with an optional note underneath.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    private let content: Content
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            VStack(spacing: 0) { content }
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
            }
        }
    }
}

/// One line in a group: a title (and optional explanation) on the left, a control on the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    private let trailing: Trailing
    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }       // the last row's line sits on the card edge
    }
}

/// A row whose control is an on/off switch.
struct SettingToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var body: some View {
        SettingRow(title, subtitle: subtitle) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
        }
    }
}

/// A row that holds anything (a grid of pets, a block of results). Gets the same padding and divider as the others.
struct SettingBlock<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// A coloured status line with an icon: green for good, orange for a warning, red for a problem.
struct SettingStatus: View {
    enum Kind { case good, warning, bad, info }
    let text: String
    var kind: Kind = .info
    private var color: Color { switch kind { case .good: .green; case .warning: .orange; case .bad: .red; case .info: .secondary } }
    private var symbol: String { switch kind { case .good: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .bad: "xmark.octagon.fill"; case .info: "info.circle" } }
    var body: some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}

// MARK: - Dropdown

struct SettingOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var subtitle: String? = nil
    var id: Value { value }
}

/// The one dropdown used everywhere in Settings. A quiet pill that opens a list where every choice has a title and,
/// when useful, a one-line explanation. Replaces the stock pop-up menu, which can only show a single line per choice.
struct DropdownPicker<Value: Hashable>: View {
    let options: [SettingOption<Value>]
    @Binding var selection: Value
    var minWidth: CGFloat = 150
    var menuWidth: CGFloat = 320
    @State private var open = false
    @Environment(\.isEnabled) private var isEnabled

    private var current: SettingOption<Value>? { options.first { $0.value == selection } }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(current?.title ?? "Choose…").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(minWidth: minWidth, maxWidth: 260)
            .background(Color.white.opacity(open ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(open ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: open ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: open)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(options) { option in
                    DropdownRow(option: option, selected: option.value == selection) { selection = option.value; open = false }
                }
            }
            .padding(6).frame(width: menuWidth)
        }
    }
}

private struct DropdownRow<Value: Hashable>: View {
    let option: SettingOption<Value>
    let selected: Bool
    let pick: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent).opacity(selected ? 1 : 0).frame(width: 14).padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(.body)
                    if let s = option.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(hovering ? 0.10 : (selected ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Number stepper

/// A compact − 5 + control.
struct NumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value - step >= range.lowerBound) { value = max(range.lowerBound, value - step) }
            Text("\(value)").font(.body.monospacedDigit()).frame(minWidth: 38)
            button("plus", enabled: value + step <= range.upperBound) { value = min(range.upperBound, value + step) }
        }
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
    }
    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - Helpers

/// Choices for a "how much text" setting. If the saved value is not one of the presets (an older version allowed any number),
/// it is shown as "Custom" so the dropdown never claims a value that is not set.
func characterOptions(_ presets: [(value: Int, title: String)], current: Int) -> [SettingOption<Int>] {
    var out = presets.map { SettingOption(value: $0.value, title: $0.title, subtitle: "\($0.value.formatted()) characters") }
    if !presets.contains(where: { $0.value == current }) { out.append(SettingOption(value: current, title: "Custom", subtitle: "\(current.formatted()) characters")) }
    return out
}
