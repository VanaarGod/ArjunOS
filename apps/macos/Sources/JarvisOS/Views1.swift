import SwiftUI
import JarvisCore

struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Models").font(.largeTitle.bold())
                    Spacer()
                    Button { Task { await model.rescan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                }
                ollamaBanner
                Text("Providers").font(.title3.bold())
                if model.providers.isEmpty { Text("No endpoints probed yet.").foregroundStyle(.secondary) }
                ForEach(Array(model.providers.enumerated()), id: \.element.id) { i, p in ProviderCard(p: p).staggerIn(i) }
                HStack {
                    TextField("Add endpoint, e.g. http://127.0.0.1:1234/v1", text: $url).glassField()
                    Button("Add") { let u = url; url = ""; Task { await model.addEndpoint(u) } }.disabled(url.isEmpty)
                }
                Text("Discovery probes loopback only and never sends prompts or keys. LAN scanning is off.").font(.caption).foregroundStyle(.secondary)

                Text("Installed models").font(.title3.bold())
                if model.models.filter({ $0.modelID != nil }).isEmpty {
                    Text("No models detected. Install Ollama and pull a model yourself (e.g. `ollama pull llama3.2:3b`); ArjunOS never downloads model weights without your approval.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.models.filter { $0.modelID != nil }.enumerated()), id: \.element.id) { i, m in ModelRow(m: m).staggerIn(i) }
                ForEach(model.models.filter { $0.error != nil }) { m in ErrorStrip(text: "\(m.endpoint): \(m.error!.kind) — \(m.error!.message)") }
            }
            .padding(24).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var ollamaBanner: some View {
        let o = model.ollama
        HStack(spacing: 12) {
            Image(systemName: o != nil ? "checkmark.seal.fill" : "bolt.slash").font(.title2).foregroundStyle(o != nil ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                if let o {
                    Text("Connected to Ollama").bold()
                    Text("v\(o.version ?? "?") · \(o.models.count) model\(o.models.count == 1 ? "" : "s") found automatically at \(o.key)").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Ollama not detected").bold()
                    Text("Start Ollama and it connects automatically (checked every few seconds at 127.0.0.1:11434).").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: (o != nil ? Color.green : Color.orange).opacity(0.25))
    }
}

struct ProviderCard: View {
    let p: Provider
    private var detail: String {
        guard p.isUsable else { return p.lastError ?? p.status }
        var text = "\(p.status) · \(p.models.count) models"
        if let ms = p.latencyMs { text += String(format: " · %.0f ms", ms) }
        return text
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: p.isUsable ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(p.isUsable ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(p.kind == "ollama" ? "Ollama" : p.kind)  ·  \(p.key)").font(.body.monospaced())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(p.owner).font(.caption2).padding(.horizontal, 8).padding(.vertical, 3).background(Color.white.opacity(0.08), in: Capsule())
        }
        .padding(14).liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let m: ModelEntry
    private var key: String { "\(m.endpoint)|\(m.modelID ?? "")" }
    private var subtitle: String {
        var parts: [String] = []
        if let b = m.sizeBytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)) }
        if let q = m.quantization { parts.append(q) }
        if let c = m.contextLength { parts.append("\(c) ctx") }
        parts.append(m.endpoint)
        return parts.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.modelID ?? "").font(.body.weight(.medium)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            CapChip(name: "tools", v: m.capabilities?.tools)
            CapChip(name: "vision", v: m.capabilities?.vision)
            if model.selectedModelKey == key { Label("Default", systemImage: "checkmark").font(.caption.bold()).foregroundStyle(Theme.accent) }
            else { Button("Use") { model.selectModel(key) } }
        }
        .padding(14).liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Unknown capabilities render as unknown, never as a guess.
struct CapChip: View {
    let name: String
    let v: Bool?
    var body: some View {
        Text(v == nil ? "\(name)?" : (v! ? name : "no \(name)"))
            .font(.caption2).padding(.horizontal, 7).padding(.vertical, 3)
            .background((v == true ? Color.green : Color.white).opacity(v == true ? 0.22 : 0.07), in: Capsule())
            .foregroundStyle(v == true ? Color.green : Color.secondary)
            .help(v == nil ? "Capability not reported by the engine" : "")
    }
}
