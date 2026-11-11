import Foundation
import CoreGraphics

// MARK: - The Codex pet format
//
// A pet is a folder with a `pet.json` and one spritesheet (WebP or PNG):
//
//   gojo-satoru/
//     pet.json          { "id", "displayName", "description", "spritesheetPath" }
//     spritesheet.webp  an atlas of 8 columns x 9 rows (the standard sheet is 1536 x 1872, so 192 x 208 per frame)
//
// Each row is one animation. Frames run left to right; unused cells at the end of a row are transparent.

public enum CodexPetState: String, CaseIterable, Sendable, Hashable {
    case idle, runningRight = "running-right", runningLeft = "running-left", waving, jumping, failed, waiting, running, review

    /// Row in the atlas (0 = top).
    public var row: Int {
        switch self {
        case .idle: 0; case .runningRight: 1; case .runningLeft: 2; case .waving: 3; case .jumping: 4
        case .failed: 5; case .waiting: 6; case .running: 7; case .review: 8
        }
    }
    /// How many frames the standard sheet has in that row.
    public var frameCount: Int {
        switch self {
        case .idle: 6; case .runningRight: 8; case .runningLeft: 8; case .waving: 4; case .jumping: 5
        case .failed: 8; case .waiting: 6; case .running: 6; case .review: 6
        }
    }
    public var framesPerSecond: Double {
        switch self {
        case .idle: 4; case .waiting: 4; case .review: 4
        case .waving: 7; case .jumping: 8; case .failed: 7
        case .running: 10; case .runningRight: 12; case .runningLeft: 12
        }
    }
}

public enum CodexPetAtlas {
    public static let columns = 8
    public static let rows = 9
    public static let referenceSheet = CGSize(width: 1536, height: 1872)

    /// The size of one frame, or nil when the sheet cannot be an 8 x 9 atlas (so a wrong file is rejected rather than drawn as noise).
    public static func cellSize(sheetWidth: Int, sheetHeight: Int) -> CGSize? {
        guard sheetWidth > 0, sheetHeight > 0, sheetWidth % columns == 0, sheetHeight % rows == 0 else { return nil }
        let cell = CGSize(width: sheetWidth / columns, height: sheetHeight / rows)
        let reference = referenceSheet.width / CGFloat(columns) / (referenceSheet.height / CGFloat(rows))      // frames are slightly taller than wide
        return abs(cell.width / cell.height - reference) < 0.12 ? cell : nil
    }

    /// Where a frame lives in the sheet, with the origin at the TOP left (the way CGImage.cropping expects it).
    public static func cellRect(state: CodexPetState, frame: Int, cell: CGSize) -> CGRect {
        CGRect(x: CGFloat(frame) * cell.width, y: CGFloat(state.row) * cell.height, width: cell.width, height: cell.height)
    }
}

public struct CodexPetManifest: Decodable, Sendable {
    public var id: String?
    public var displayName: String?
    public var description: String?
    public var spritesheetPath: String?
}

public struct CodexPetInfo: Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable { case app, codex }
    public var id: String
    public var name: String
    public var description: String
    public var folder: URL
    public var spritesheet: URL
    public var source: Source
}

public enum PetLibrary {
    public static let maxSheetBytes = 25 * 1024 * 1024
    public static let allowedExtensions: Set<String> = ["webp", "png"]

    /// Where pets are looked for, in priority order: this app's own folder first, then Codex's (`$CODEX_HOME/pets`, default `~/.codex/pets`).
    public static func searchDirectories(home: URL, appSupport: URL, environment: [String: String] = [:]) -> [(url: URL, source: CodexPetInfo.Source)] {
        var codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        if let custom = environment["CODEX_HOME"], !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            codexHome = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return [(appSupport.appendingPathComponent("pets", isDirectory: true), .app), (codexHome.appendingPathComponent("pets", isDirectory: true), .codex)]
    }

    /// A pet id is used as a lookup key and a folder name, so keep it to plain characters.
    public static func sanitizedID(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".-")).prefix(80))
    }

    /// The spritesheet inside `folder`, or nil if the path is absolute, climbs out of the folder, points at a link outside it,
    /// has the wrong extension, is missing, or is too big. A pet.json can never make the app read some other file.
    public static func resolveSpritesheet(folder: URL, relative: String) -> URL? {
        let rel = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.hasPrefix("~"), !rel.contains("\0"),
              !rel.split(separator: "/").contains(where: { $0 == ".." }) else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(rel).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), allowedExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0 && size <= maxSheetBytes ? file : nil
    }

    /// Reads one pet folder. Nil when it is not a usable pet.
    public static func load(folder: URL, source: CodexPetInfo.Source) -> CodexPetInfo? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("pet.json")), data.count < 64 * 1024,
              let manifest = try? JSONDecoder().decode(CodexPetManifest.self, from: data) else { return nil }
        let folderName = folder.lastPathComponent
        var id = sanitizedID(manifest.id ?? "")
        if id.isEmpty { id = sanitizedID(folderName) }
        guard !id.isEmpty else { return nil }
        guard let sheet = resolveSpritesheet(folder: folder, relative: manifest.spritesheetPath ?? "spritesheet.webp")
                ?? (manifest.spritesheetPath == nil ? resolveSpritesheet(folder: folder, relative: "spritesheet.png") : nil) else { return nil }
        let name = (manifest.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = (manifest.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexPetInfo(id: id, name: String((name.isEmpty ? id : name).prefix(60)), description: String(desc.prefix(300)), folder: folder, spritesheet: sheet, source: source)
    }

    /// Every usable pet in the given directories. When two folders use the same id, the earlier directory wins.
    public static func scan(_ directories: [(url: URL, source: CodexPetInfo.Source)]) -> (pets: [CodexPetInfo], skipped: [String]) {
        var found: [CodexPetInfo] = [], seen = Set<String>(), skipped: [String] = []
        for dir in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: dir.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for url in entries.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                guard let pet = load(folder: url, source: dir.source) else {
                    if FileManager.default.fileExists(atPath: url.appendingPathComponent("pet.json").path) { skipped.append(url.lastPathComponent) }
                    continue
                }
                if seen.insert(pet.id).inserted { found.append(pet) }
            }
        }
        return (found, skipped)
    }

    public static func pet(withID id: String?, in pets: [CodexPetInfo]) -> CodexPetInfo? {
        guard let id, !id.isEmpty else { return nil }
        return pets.first { $0.id == id }
    }
}
