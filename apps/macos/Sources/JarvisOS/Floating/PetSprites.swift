import SwiftUI
import AppKit
import ImageIO
import JarvisCore

/// A Codex pet decoded into animation frames. The sheet is cut into frames once; drawing a frame afterwards is free.
struct PetSprite {
    let info: CodexPetInfo
    private let frames: [CodexPetState: [CGImage]]

    private init(info: CodexPetInfo, frames: [CodexPetState: [CGImage]]) { self.info = info; self.frames = frames }

    /// The frames for a state; a state the pet does not have falls back to its idle animation.
    func frames(for state: CodexPetState) -> [CGImage] { frames[state] ?? frames[.idle] ?? [] }
    var thumbnail: CGImage? { frames[.idle]?.first }

    static func load(_ info: CodexPetInfo) -> PetSprite? {
        guard let source = CGImageSourceCreateWithURL(info.spritesheet as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cell = CodexPetAtlas.cellSize(sheetWidth: sheet.width, sheetHeight: sheet.height) else { return nil }
        var all: [CodexPetState: [CGImage]] = [:]
        for state in CodexPetState.allCases {
            var list: [CGImage] = []
            for index in 0..<state.frameCount {
                guard let frame = sheet.cropping(to: CodexPetAtlas.cellRect(state: state, frame: index, cell: cell)), !isBlank(frame) else { break }
                list.append(frame)
            }
            if !list.isEmpty { all[state] = list }
        }
        guard all[.idle] != nil else { return nil }
        return PetSprite(info: info, frames: all)
    }

    /// True when a frame has no visible pixels (an unused cell at the end of a row).
    private static func isBlank(_ image: CGImage) -> Bool {
        let w = 24, h = 26
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var i = 3
        while i < w * h * 4 {
            if bytes[i] > 8 { return false }
            i += 4
        }
        return true
    }
}

/// Plays one animation of a pet. Draws a still frame when motion is reduced.
struct PetSpriteView: View {
    let sprite: PetSprite
    let state: CodexPetState
    var animate = true

    var body: some View {
        let frames = sprite.frames(for: state)
        if frames.isEmpty {
            Color.clear
        } else if animate && frames.count > 1 {
            TimelineView(.periodic(from: Date(), by: 1.0 / state.framesPerSecond)) { context in
                let index = Int(context.date.timeIntervalSinceReferenceDate * state.framesPerSecond) % frames.count
                frameView(frames[index])
            }
        } else {
            frameView(frames[0])
        }
    }

    private func frameView(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.medium).scaledToFit()
    }
}

enum PetInstallError: LocalizedError {
    case unreadable, notAPet, tooBig, extractFailed(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: "That file or folder couldn't be read."
        case .notAPet: "That isn't a Codex pet. A pet is a folder with a pet.json and a spritesheet (an 8 by 9 grid of frames), or a .zip of one."
        case .tooBig: "That pet is too large."
        case .extractFailed(let m): "The zip couldn't be opened: \(m)"
        }
    }
}

/// The pets available to the app: this app's own folder, plus Codex's (`~/.codex/pets`).
@MainActor @Observable
final class PetLibraryModel {
    private(set) var pets: [CodexPetInfo] = []
    private(set) var skipped: [String] = []
    var lastError: String?

    @ObservationIgnored private var cache: [String: PetSprite] = [:]
    @ObservationIgnored private var failed: Set<String> = []

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("JarvisOS", isDirectory: true)
    }
    var directories: [(url: URL, source: CodexPetInfo.Source)] {
        PetLibrary.searchDirectories(home: FileManager.default.homeDirectoryForCurrentUser, appSupport: Self.appSupport, environment: ProcessInfo.processInfo.environment)
    }
    var appPetsDirectory: URL { directories[0].url }

    func rescan() {
        try? FileManager.default.createDirectory(at: appPetsDirectory, withIntermediateDirectories: true)        // somewhere to drop pets, even before you have any
        let result = PetLibrary.scan(directories)
        pets = result.pets; skipped = result.skipped
        cache.removeAll(); failed.removeAll()
    }

    /// The decoded pet for an id, or nil (no id, not installed, or its sheet is unusable). Cheap to call while drawing.
    func sprite(for id: String?) -> PetSprite? {
        guard let info = PetLibrary.pet(withID: id, in: pets) else { return nil }
        let key = info.spritesheet.path
        if let hit = cache[key] { return hit }
        if failed.contains(key) { return nil }
        guard let loaded = PetSprite.load(info) else { failed.insert(key); return nil }
        cache[key] = loaded
        return loaded
    }

    /// Shows the app's pets folder in Finder, creating it first so there is somewhere to drop pets.
    func revealFolder() {
        try? FileManager.default.createDirectory(at: appPetsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([appPetsDirectory])
    }

    /// Installs a pet from a folder or a .zip into the app's pets folder.
    func install(from url: URL) async throws -> CodexPetInfo {
        let destination = appPetsDirectory
        let info = try await Task.detached(priority: .userInitiated) { try Self.installSync(url, into: destination) }.value
        rescan()
        return info
    }

    nonisolated private static func installSync(_ url: URL, into destination: URL) throws -> CodexPetInfo {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw PetInstallError.unreadable }
        let scratch = fm.temporaryDirectory.appendingPathComponent("arjunos-pet-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        var searchRoot = url
        if !isDir.boolValue {
            guard url.pathExtension.lowercased() == "zip" else { throw PetInstallError.notAPet }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, scratch.path]
            let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
            do { try p.run() } catch { throw PetInstallError.extractFailed(error.localizedDescription) }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw PetInstallError.extractFailed(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error")
            }
            try sanitizeExtracted(scratch)
            searchRoot = scratch
        }
        guard let folder = findPetFolder(in: searchRoot, depth: 2), let info = PetLibrary.load(folder: folder, source: .app) else { throw PetInstallError.notAPet }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(info.id, isDirectory: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: folder, to: target)
        guard let installed = PetLibrary.load(folder: target, source: .app) else { try? fm.removeItem(at: target); throw PetInstallError.notAPet }
        return installed
    }

    /// After unzipping: refuse a zip that expands to something huge, and delete any links (a link could point outside the pet's folder).
    nonisolated private static func sanitizeExtracted(_ root: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey], options: []) else { return }
        var total = 0
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true { try? fm.removeItem(at: item); continue }
            total += values?.fileSize ?? 0
            if total > 80 * 1024 * 1024 { throw PetInstallError.tooBig }
        }
    }

    /// The folder holding pet.json: the root itself or a folder up to `depth` levels down (ignoring macOS's __MACOSX clutter).
    nonisolated private static func findPetFolder(in root: URL, depth: Int) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("pet.json").path) { return root }
        guard depth > 0, let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for entry in entries where entry.lastPathComponent != "__MACOSX" {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, let found = findPetFolder(in: entry, depth: depth - 1) { return found }
        }
        return nil
    }
}
