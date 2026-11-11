import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JarvisCore

enum FileIcon {
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "pdf": "doc.richtext"
        case "docx": "doc.text"
        case "xlsx": "tablecells"
        case "pptx": "rectangle.on.rectangle.angled"
        case "odf", "rtf", "epub": "doc.text"
        case "sqlite": "cylinder.split.1x2"
        case "archive", "iwork": "archivebox"
        case "folder": "folder"
        case "legacy", "binary": "doc.questionmark"
        case "html": "globe"
        case "image": "photo"
        default: "doc.plaintext"
        }
    }
    static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

/// Decodes the stored base64 JPEG lazily and caches the result (images can be large; never decode on every redraw).
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(for a: Attachment) -> NSImage? {
        guard let b64 = a.imageBase64 else { return nil }
        let key = a.id.uuidString as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = Data(base64Encoded: b64), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key); return img
    }
}

struct AttachmentThumb: View {
    let attachment: Attachment
    var size: CGFloat = 34
    var body: some View {
        if let img = ThumbnailCache.image(for: attachment) {
            Image(nsImage: img).resizable().scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: FileIcon.symbol(attachment.kind)).font(.system(size: size * 0.5)).foregroundStyle(Theme.accent).frame(width: size, height: size)
        }
    }
}

/// A file waiting to be sent (reading → ready, or failed with the reason).
struct DraftChip: View {
    @Environment(AppModel.self) private var model
    let draft: DraftAttachment

    var body: some View {
        HStack(spacing: 8) {
            switch draft.state {
            case .reading: ProgressView().controlSize(.small).frame(width: 34, height: 34)
            case .ready: if let a = draft.attachment { AttachmentThumb(attachment: a) }
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange).frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.name).font(.callout).lineLimit(1).truncationMode(.middle)
                switch draft.state {
                case .reading: Text("Reading…").font(.caption2).foregroundStyle(.secondary)
                case .failed(let m): Text(m).font(.caption2).foregroundStyle(Color.orange).lineLimit(3).help(m)
                case .ready:
                    if let note = draft.attachment?.note { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    else { Text(FileIcon.size(draft.bytes)).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Button { model.removeDraft(draft.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove")
        }
        .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: 280, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(draft.state == .reading ? Theme.hairline : Color.clear))
        .help(draft.name)
    }
}

/// Files shown under a sent user message.
struct AttachmentChips: View {
    let attachments: [Attachment]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { a in
                HStack(spacing: 8) {
                    AttachmentThumb(attachment: a, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(a.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text(FileIcon.size(a.bytes)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 5).frame(maxWidth: 220, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc").font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("Drop files to attach").font(.title3.weight(.semibold))
                Text("Any file: documents, slides, spreadsheets, code, images, archives…").font(.callout).foregroundStyle(.secondary)
            })
            .padding(18).allowsHitTesting(false)
    }
}

enum FilePicker {
    @MainActor static func pick(into model: AppModel) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.canChooseFiles = true
        p.message = "Choose files to attach (any type)"
        if p.runModal() == .OK { model.addFiles(p.urls) }
    }
}
