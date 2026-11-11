import SwiftUI
import UniformTypeIdentifiers
import JarvisCore

/// Crew: one boss agent splits a job, small worker agents do the pieces (each with its own browser panel),
/// and the boss assembles the answer. Which models are awake depends on this Mac's free memory.
struct CrewView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        let crew = model.crew
        HStack(spacing: 0) {
            CrewSetup().frame(width: 344)
            Divider().opacity(0.4)
            CrewStage()
        }
        .overlay { if dropTargeted { DropOverlay() } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard !crew.isRunning else { return false }
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) } else if let u = item as? URL { url = u }
                    if let url { Task { @MainActor in crew.addFiles([url]) } }
                }
            }
            return true
        }
        .task {                                                      // keep the memory meter live while this screen is visible
            while !Task.isCancelled { if !model.windowIdle { await crew.refreshResources() }; try? await Task.sleep(nanoseconds: 3_000_000_000) }
        }
        .onAppear { crew.attach(model); crew.schedulePreview() }
        .onChange(of: crew.bossRef) { _, _ in crew.schedulePreview() }
        .onChange(of: crew.workerRef) { _, _ in crew.schedulePreview() }
        .onChange(of: crew.preference) { _, _ in crew.schedulePreview() }
    }
}

// MARK: - Setup column

private struct CrewSetup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var crew = model.crew
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Crew").font(.title2.weight(.semibold))
                    Text("Give the boss a job. It splits it up, small workers do the reading, and the boss puts the answer together.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                section("The job") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $crew.task).font(.system(size: 13)).scrollContentBackground(.hidden)
                            .frame(minHeight: 96, maxHeight: 160).padding(6)
                        if crew.task.isEmpty {
                            Text("e.g. Read these PDFs and tell me how they differ.").font(.system(size: 13)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 12).padding(.vertical, 14).allowsHitTesting(false)
                        }
                    }
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(crew.isRunning)
                }

                section("Files") {
                    if crew.files.isEmpty {
                        Button { crew.pickFiles() } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "doc.badge.plus").font(.title2).foregroundStyle(.secondary)
                                Text("Drop PDFs, images or documents here").font(.caption).foregroundStyle(.secondary)
                                Text("or click to choose").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(Theme.hairline))
                        }.buttonStyle(.plain).disabled(crew.isRunning)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(crew.files) { f in FileRow(file: f) }
                            Button { crew.pickFiles() } label: { Label("Add more", systemImage: "plus").font(.caption) }
                                .buttonStyle(.plain).foregroundStyle(Theme.accent).disabled(crew.isRunning || crew.files.count >= 12)
                        }
                    }
                }

                section("Models") {
                    LabeledMenu(title: "Boss", systemImage: "crown") {
                        CrewModelMenu(selection: $crew.bossRef, autoLabel: nil)
                    }
                    LabeledMenu(title: "Workers", systemImage: "person.3") {
                        CrewModelMenu(selection: $crew.workerRef, autoLabel: "Automatic: smallest capable model")
                    }
                    Text(crew.workerRef == nil ? "Workers use the smallest installed model that can do the job (a vision model for scanned pages). You can also pick a model for a single file above."
                                               : "Every worker uses this model unless you pick a different one for a file.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                section("Memory") {
                    DropdownPicker(options: CrewPreference.allCases.map { SettingOption(value: $0, title: $0.title, subtitle: $0.summary) },
                                   selection: $crew.preference, minWidth: 200, menuWidth: 340)
                        .disabled(crew.isRunning)
                    Toggle("The boss reviews the reports", isOn: $crew.review).disabled(crew.isRunning)
                    Text("Before writing the final answer the boss checks each report against its job, sends weak ones back once, and can add workers for anything missing.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    CrewPlanCard(plan: crew.isRunning ? crew.plan : (crew.preview?.plan ?? crew.plan), error: crew.previewError)
                    MemoryMeter()
                }

                actions
            }
            .padding(18)
        }
    }

    @ViewBuilder private var actions: some View {
        let crew = model.crew
        if crew.isRunning {
            Button { crew.cancel() } label: { Label("Stop the crew", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                .buttonStyle(GlassButtonStyle())
        } else {
            Button { crew.start() } label: { Label(crew.phase == .finished ? "Run again" : "Start the crew", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .buttonStyle(GlassButtonStyle(prominent: true)).disabled(!crew.canStart || (crew.preview.map { !$0.plan.feasible } ?? false))
            if crew.phase == .finished {
                Button { crew.reset(keepSetup: true) } label: { Text("Clear results").frame(maxWidth: .infinity) }.buttonStyle(GlassButtonStyle())
            }
            if crew.filesReading { Label("Reading your files…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary) }
            else if crew.bossRef == nil { Text("Pick a boss model first.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
    }
}

private struct LabeledMenu<M: View>: View {
    let title: String, systemImage: String
    @ViewBuilder let menu: () -> M
    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage).font(.callout).frame(width: 92, alignment: .leading)
            menu().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CrewModelMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    let autoLabel: String?

    private func ref(_ m: ModelEntry) -> String { "\(m.endpoint)|\(m.modelID ?? "")" }
    var body: some View {
        Menu {
            if let autoLabel { Button { selection = nil } label: { if selection == nil { Label(autoLabel, systemImage: "checkmark") } else { Text(autoLabel) } }; Divider() }
            if model.chatModels.isEmpty { Text("No models detected") }
            ForEach(model.chatModels) { m in
                Button { selection = ref(m) } label: {
                    let name = AppModel.shortModelName(m.modelID ?? "") + (m.sizeBytes.map { "  ·  " + crewBytes($0) } ?? "") + (m.capabilities?.vision == true ? "  ·  vision" : "")
                    if selection == ref(m) { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.map { AppModel.shortModelName(crewModelName($0)) } ?? (autoLabel != nil ? "Automatic" : "Choose…")).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: 170, alignment: .trailing)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: CrewModel.InputFile
    var body: some View {
        let crew = model.crew
        HStack(spacing: 8) {
            Image(systemName: file.kind == "image" ? "photo" : "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Group {
                    switch file.state {
                    case .reading: Text("Reading…")
                    case .failed(let m): Text(m).foregroundStyle(.red)
                    case .ready:
                        Text([file.pages.map { "\($0) pages" }, file.scanned ? "scanned: vision" : (file.kind == "image" ? "image: vision" : "\(file.text.count.formatted()) characters")].compactMap { $0 }.joined(separator: " · "))
                    }
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if file.state == .ready && !crew.isRunning {
                Menu {
                    Button("Automatic") { crew.setWorkerModel(file.id, nil) }
                    Divider()
                    ForEach(model.chatModels) { m in Button(AppModel.shortModelName(m.modelID ?? "")) { crew.setWorkerModel(file.id, "\(m.endpoint)|\(m.modelID ?? "")") } }
                } label: { Image(systemName: file.workerModel == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark").foregroundStyle(file.workerModel == nil ? Color.secondary : Theme.accent) }
                .menuStyle(.borderlessButton).fixedSize().help(file.workerModel.map { "Worker model: \(crewModelName($0))" } ?? "Worker model: automatic")
            }
            if !crew.isRunning { Button { crew.removeFile(file.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Memory

private struct CrewPlanCard: View {
    let plan: CrewPlanInfo?
    let error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan {
                HStack(spacing: 6) {
                    Image(systemName: plan.feasible ? modeSymbol(plan.mode) : "exclamationmark.triangle.fill").foregroundStyle(plan.feasible ? Theme.accent : .orange)
                    Text(plan.feasible ? (CrewMode(rawValue: plan.mode ?? "")?.title ?? "Ready") : "Won't fit right now").font(.callout.weight(.medium))
                    Spacer()
                    if plan.feasible && plan.maxWorkers > 1 { Text("up to \(plan.maxWorkers) workers at once").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(plan.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(plan.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else {
                Text("Pick a boss model to see how it will fit in memory.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundRectangle(10))
    }
    private func modeSymbol(_ m: String?) -> String { m == "parallel" ? "person.3.fill" : (m == "boss_plus_one" ? "person.2.fill" : (m == "boss_sleeps" ? "moon.stars.fill" : "moon.zzz.fill")) }
}

private func RoundRectangle(_ r: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: r, style: .continuous) }

/// Live view of this Mac's memory and which models are awake. Shown during the run too, so you can see the boss go to sleep.
struct MemoryMeter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let crew = model.crew
        let m = crew.memory
        let total = m?.total ?? crew.resources?.total ?? 0
        let avail = m?.available ?? crew.resources?.available ?? 0
        let pressure = m?.pressure ?? crew.resources?.pressure ?? "normal"
        let loaded = loadedModels()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory").font(.caption.weight(.medium))
                Spacer()
                if total > 0 { Text("\(crewBytes(avail)) free of \(crewBytes(total))").font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
            }
            GeometryReader { geo in
                let used = total > 0 ? CGFloat(1 - Double(avail) / Double(total)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color(pressure)).frame(width: max(4, geo.size.width * min(max(used, 0), 1)))
                }
            }
            .frame(height: 8).animation(Theme.smooth, value: avail)
            hardwareLine(m)
            if !loaded.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(loaded, id: \.0) { ref, bytes in
                        HStack(spacing: 6) {
                            Circle().fill(role(ref).color).frame(width: 6, height: 6)
                            Text(AppModel.shortModelName(crewModelName(ref))).font(.caption2).lineLimit(1).truncationMode(.middle)
                            Text(role(ref).label).font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text(crewBytes(bytes)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } else if total > 0 {
                Text("No model is loaded right now.").font(.caption2).foregroundStyle(.secondary)
            }
            if pressure != "normal" { Label(pressure == "critical" ? "Memory is nearly full." : "Memory is getting tight.", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(color(pressure)) }
        }
        .padding(10).background(Color.white.opacity(0.05), in: RoundRectangle(10))
    }

    @ViewBuilder private func hardwareLine(_ live: CrewMemory?) -> some View {
        let r = model.crew.resources
        let cpu = live?.cpuPercent ?? r?.cpuPercent
        let gpu = (live?.gpuName ?? r?.gpuName) ?? ""
        let limit = live?.gpuLimit ?? r?.gpuLimit
        if cpu != nil || !gpu.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let cpu { Label("CPU \(Int(cpu))% busy", systemImage: "cpu").font(.caption2).foregroundStyle(cpu > 85 ? Color.orange : Color.secondary) }
                if !gpu.isEmpty { Label(gpu + (limit.map { " · models up to " + crewBytes($0) } ?? ""), systemImage: "bolt.horizontal").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }

    /// Models in memory: the live reading during a run, otherwise the last background reading.
    private func loadedModels() -> [(String, Int)] {
        let crew = model.crew
        if let live = crew.memory?.loaded { return live.map { ($0.ref, $0.bytes) } }
        if let idle = crew.resources?.loaded { return idle.map { ($0.ref, $0.bytes) } }
        return []
    }

    private func color(_ p: String) -> Color { p == "critical" ? .red : (p == "warn" ? .orange : Theme.accent) }
    private func role(_ ref: String) -> (label: String, color: Color) {
        let crew = model.crew
        if crew.boss?.model == ref || crew.bossRef == ref { return ("boss", Theme.accent) }
        if crew.workers.contains(where: { $0.model == ref }) || crew.workerRef == ref { return ("worker", .green) }
        return ("other", .secondary)
    }
}

// MARK: - Stage (panels)

private struct CrewStage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let crew = model.crew
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if crew.agents.isEmpty { intro } else {
                    header
                    if let e = crew.error { ErrorStrip(text: e) }
                    ApprovalBanner()                                            // a worker wants to run a command and needs your OK
                    ForEach(crew.needsUser) { NeedsYouCard(item: $0) }
                    CrewGraphView()
                    CrewWorkspace()
                    if !crew.finalText.isEmpty { FinalCard() }
                    Timeline()
                }
            }
            .padding(18)
            .animation(Theme.smooth, value: crew.agents.count)
        }
    }

    private var header: some View {
        let crew = model.crew
        return HStack(spacing: 10) {
            if crew.isRunning { ProgressView().controlSize(.small) }
            else { Image(systemName: crew.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(crew.error == nil ? Color.green : .orange) }
            Text(crew.isRunning ? "The crew is working" : (crew.error == nil ? "Finished" : "Stopped")).font(.headline)
            if let p = crew.plan, let mode = CrewMode(rawValue: p.mode ?? "") { Text(mode.title).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent.opacity(0.18), in: Capsule()) }
            Spacer()
            if !crew.conventions.isEmpty {
                Text("\(crew.conventions.count) shared rules").font(.caption2).foregroundStyle(.secondary).help(crew.conventions.joined(separator: "\n"))
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How the crew works").font(.title3.weight(.semibold))
            step("1", "You give the boss a job", "For example, attach 2 or 3 PDFs and say what you want to know.")
            step("2", "The boss splits it up", "Each file goes to its own worker. Workers read with vision when a PDF is a scan, and write a very detailed report.")
            step("3", "Workers ask, share and browse", "A worker can ask the boss a question, share a fact with the team, read a colleague's report, and open web pages in its own browser panel.")
            step("4", "If something breaks, it comes back to you", "The boss tries to fix a stuck worker first. If that fails, you decide: retry with new instructions, or skip it.")
            step("5", "Your RAM decides who is awake", "With plenty of memory everyone runs together. With less, workers take turns. With very little, only one model is awake at a time: the boss sleeps while workers work, and wakes up only to answer a question.")
        }
        .padding(8).frame(maxWidth: 560, alignment: .leading)
    }
    private func step(_ n: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(.callout.weight(.semibold)).frame(width: 26, height: 26).background(Theme.accent.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.callout.weight(.medium)); Text(d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct NeedsYouCard: View {
    @Environment(AppModel.self) private var model
    let item: CrewEvent.NeedsUser
    @State private var text = ""
    var body: some View {
        let crew = model.crew
        VStack(alignment: .leading, spacing: 8) {
            Label(item.kind == "worker_failed" ? "A worker is stuck" : "The boss needs your decision", systemImage: "hand.raised.fill").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            Text(item.question).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(item.kind == "worker_failed" ? "New instructions, or leave empty to just retry…" : "Your answer…", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button("Send") { crew.reply(to: item, text: text.isEmpty ? "Retry" : text) }.buttonStyle(GlassButtonStyle(prominent: true))
                if item.kind == "worker_failed" { Button("Skip it") { crew.reply(to: item, text: "skip") }.buttonStyle(GlassButtonStyle()) }
            }
        }
        .padding(14).background(Color.orange.opacity(0.12), in: RoundRectangle(14)).overlay(RoundRectangle(14).strokeBorder(Color.orange.opacity(0.4)))
    }
}

private struct FinalCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let crew = model.crew
        VStack(alignment: .leading, spacing: 10) {
            Label("Final answer from the boss", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.accent)
            RichText(key: "crew-final", markdown: crew.finalText)
            HStack {
                Button { crew.continueInChat() } label: { Label("Keep going in chat", systemImage: "bubble.left.and.bubble.right") }.buttonStyle(GlassButtonStyle(prominent: true))
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(crew.finalText, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(GlassButtonStyle())
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(crew.contextText, forType: .string) } label: { Label("Copy all worker reports", systemImage: "doc.on.doc.fill") }.buttonStyle(GlassButtonStyle())
            }
            Text("\"Keep going in chat\" opens a normal chat that already contains this answer and every worker's full report as context.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16).liquidGlass(in: RoundRectangle(18), tint: Theme.accent.opacity(0.10)).overlay(RoundRectangle(18).strokeBorder(Theme.accent.opacity(0.4)))
    }
}

private struct Timeline: View {
    @Environment(AppModel.self) private var model
    @State private var open = true
    var body: some View {
        let items = model.crew.timeline
        if !items.isEmpty {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items.suffix(60)) { it in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: it.icon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
                            Text(it.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }.padding(.top, 6)
            } label: { Label("Team activity", systemImage: "bubble.left.and.text.bubble.right").font(.callout.weight(.medium)) }
            .padding(14).background(Color.white.opacity(0.04), in: RoundRectangle(14))
        }
    }
}
