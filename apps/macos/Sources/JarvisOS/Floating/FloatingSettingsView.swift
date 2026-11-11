import SwiftUI
import AppKit
import JarvisCore

/// Settings → Floating assistant.
struct FloatingSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = model.floating
        let s = c.settings
        SettingsPageScaffold(.floating) {
            SettingsGroup("Display", footer: s.displayMode.summary) {
                SettingRow("Display mode") {
                    DropdownPicker(options: FloatingDisplayMode.allCases.map { m in
                        SettingOption(value: m, title: m == .default ? "\(m.title) (default)" : m.title, subtitle: m.summary)
                    }, selection: Binding(get: { c.settings.displayMode }, set: { c.setMode($0) }), minWidth: 190, menuWidth: 360)
                }
                SettingToggleRow(title: "Show the pet", isOn: Binding(get: { c.petVisible }, set: { c.setPetHidden(!$0) }))
                    .disabled(!s.displayMode.showsPet)
                SettingToggleRow(title: "Show the mini chat", isOn: Binding(get: { c.chatOpen }, set: { c.setChatOpen($0) }))
            }

            SettingsGroup("Shortcut", footer: "Shows or hides the mini chat from any app. Click the shortcut, then press the new keys. It needs Control or Command.") {
                SettingRow("Show or hide the mini chat") {
                    HStack(spacing: 10) {
                        ShortcutRecorder(controller: c)
                        Button("Reset") { c.resetHotKey() }.buttonStyle(GlassButtonStyle()).disabled(s.hotKey == .default && c.hotKeyError == nil)
                    }
                }
                if let e = c.hotKeyError { SettingBlock { SettingStatus(text: e, kind: .warning) } }
            }

            SettingsGroup("Screen", footer: "When on, each message you send from the mini chat includes a picture of the window directly behind ArjunOS (only that window, never ArjunOS itself). It goes to your local vision model and stays on this Mac. You can also switch it with the eye button in the chat.") {
                SettingToggleRow(title: "Let the mini chat see the window behind it",
                                 isOn: Binding(get: { c.settings.shareScreen }, set: { c.setShareScreen($0) }))
            }

            if s.displayMode.showsPet {
                SettingsGroup("Pet") {
                    SettingBlock { PetPicker(controller: c) }
                    if c.pets.sprite(for: c.settings.petID) == nil {            // the built-in looks only matter when no Codex pet is chosen
                        SettingRow("Classic look") {
                            DropdownPicker(options: PetStyle.allCases.map { SettingOption(value: $0, title: $0.title) },
                                           selection: Binding(get: { c.settings.petStyle }, set: { c.setStyle($0) }), minWidth: 130)
                        }
                        SettingRow("Colour") {
                            HStack(spacing: 8) {
                                ForEach(PetColor.allCases) { col in
                                    Button { c.setColor(col) } label: {
                                        Circle().fill(col.color).frame(width: 20, height: 20)
                                            .overlay(Circle().strokeBorder(.white, lineWidth: c.settings.petColor == col ? 2 : 0).padding(-3))
                                    }.buttonStyle(.plain).help(col.title).accessibilityLabel(col.title)
                                }
                            }
                        }
                    }
                    SettingRow("Size") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(get: { c.settings.petSize }, set: { c.setSize($0) }), in: FloatingSettings.petSizeRange).frame(width: 180)
                            Text("\(Int(c.settings.petSize)) pt").font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                    SettingRow("Opacity when idle") {
                        Slider(value: Binding(get: { c.settings.petIdleOpacity }, set: { c.setIdleOpacity($0) }), in: FloatingSettings.idleOpacityRange).frame(width: 220)
                    }
                    SettingRow("Position", subtitle: "You can also drag the pet anywhere. Right-click it for more options.") {
                        HStack(spacing: 6) {
                            ForEach(PetCorner.allCases) { corner in Button(corner.title) { c.movePet(to: corner) }.buttonStyle(GlassButtonStyle()).controlSize(.small) }
                            Button("Reset") { c.resetPetPosition() }.buttonStyle(GlassButtonStyle()).controlSize(.small)
                        }
                    }
                    SettingToggleRow(title: "Snap to the screen edge when I let go",
                                     isOn: Binding(get: { c.settings.snapToEdges }, set: { c.setSnap($0) }))
                }
            }

            Text("The pet and the mini chat use the same \(model.assistantName) conversation, model, memory and page awareness as the main window. The chat opens beside the pet and moves with it; drag its edges to resize it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
        }
    }
}

/// A button that shows the current shortcut and records a new one when clicked.
struct ShortcutRecorder: View {
    let controller: FloatingAssistantController
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? "Press the new shortcut…" : controller.settings.hotKey.display)
                .font(.system(size: 13, weight: .medium, design: .rounded)).frame(minWidth: 130)
        }
        .buttonStyle(GlassButtonStyle(prominent: recording))
        .accessibilityLabel("Shortcut: \(controller.settings.hotKey.spoken)")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        controller.beginShortcutRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                                                   // Esc cancels
            let combo = HotKeyCombo(keyCode: e.keyCode, modifiers: GlobalHotKey.modifiers(from: e.modifierFlags))
            if !combo.isValid { controller.hotKeyError = "A shortcut needs Control or Command, plus a key."; return nil }
            stop()
            controller.setHotKey(combo)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if recording { recording = false; controller.endShortcutRecording() }
    }
}


/// The list of pets: the classic built-in pet plus every Codex pet found in ~/.codex/pets and this app's pets folder.
struct PetPicker: View {
    let controller: FloatingAssistantController
    @State private var working = false

    var body: some View {
        let c = controller
        let library = c.pets
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pet").font(.callout.weight(.medium))
                Spacer()
                Text(library.pets.isEmpty ? "No Codex pets found yet" : "\(library.pets.count) Codex pet\(library.pets.count == 1 ? "" : "s") found").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ClassicPetCard(controller: c)
                ForEach(library.pets) { pet in PetCard(controller: c, pet: pet) }
            }
            if let chosen = c.settings.petID, PetLibrary.pet(withID: chosen, in: library.pets) == nil {
                Label("The pet “\(chosen)” isn't installed any more, so the classic pet is shown.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if let chosen = c.settings.petID, library.sprite(for: chosen) == nil {
                Label("That pet's spritesheet couldn't be read (it should be an 8 by 9 grid of frames), so the classic pet is shown.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if !library.skipped.isEmpty {
                Text("Skipped (not a valid pet): " + library.skipped.joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
            }
            if let e = library.lastError { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Button { add() } label: { Label("Add pet…", systemImage: "plus") }.buttonStyle(GlassButtonStyle()).disabled(working)
                Button { library.revealFolder() } label: { Label("Open pets folder", systemImage: "folder") }.buttonStyle(GlassButtonStyle())
                Button { library.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }.buttonStyle(GlassButtonStyle())
                if working { ProgressView().controlSize(.small) }
            }
            Text("Pets are Codex-format pets: a folder with a pet.json and a spritesheet. They are read from ~/.codex/pets (or $CODEX_HOME/pets) and from \(library.appPetsDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). \"Add pet…\" accepts a pet folder or a .zip.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { library.rescan() }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a Codex pet: its folder, or a .zip of it"; panel.prompt = "Add pet"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; controller.pets.lastError = nil
        Task {
            do {
                let info = try await controller.pets.install(from: url)
                controller.setPetID(info.id)
            } catch { controller.pets.lastError = error.localizedDescription }
            working = false
        }
    }
}

private struct PetCard: View {
    let controller: FloatingAssistantController
    let pet: CodexPetInfo
    var body: some View {
        let selected = controller.settings.petID == pet.id
        let sprite = controller.pets.sprite(for: pet.id)
        Button { controller.setPetID(pet.id) } label: {
            VStack(spacing: 6) {
                ZStack {
                    if let sprite {
                        if selected { PetSpriteView(sprite: sprite, state: .idle) }
                        else if let thumb = sprite.thumbnail { Image(decorative: thumb, scale: 1).resizable().interpolation(.medium).scaledToFit() }
                    } else {
                        Image(systemName: "questionmark.square.dashed").font(.title).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 72)
                Text(pet.name).font(.caption.weight(.medium)).lineLimit(1)
                Text(pet.source == .codex ? "Codex" : "ArjunOS").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity)
            .background(Color.white.opacity(selected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(pet.description.isEmpty ? pet.name : pet.description)
        .accessibilityLabel(pet.name)
    }
}

private struct ClassicPetCard: View {
    let controller: FloatingAssistantController
    var body: some View {
        let s = controller.settings
        let selected = controller.pets.sprite(for: s.petID) == nil
        Button { controller.setPetID(nil) } label: {
            VStack(spacing: 6) {
                Circle().fill(RadialGradient(colors: [s.petColor.color.opacity(0.95), s.petColor.color.opacity(0.25)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 40))
                    .overlay(Image(systemName: "waveform").foregroundStyle(.white))
                    .frame(width: 56, height: 56).frame(height: 72)
                Text("Classic").font(.caption.weight(.medium))
                Text("Built in").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity)
            .background(Color.white.opacity(selected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
