import XCTest
@testable import JarvisCore

final class CodexPetTests: XCTestCase {
    private func makeFolder(_ files: [String: String], name: String = "gojo") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pets-" + UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (rel, text) in files {
            let url = folder.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return folder
    }

    func testTheAtlasMatchesTheRealSheet() {
        XCTAssertEqual(CodexPetAtlas.cellSize(sheetWidth: 1536, sheetHeight: 1872), CGSize(width: 192, height: 208))
        XCTAssertEqual(CodexPetAtlas.cellSize(sheetWidth: 3072, sheetHeight: 3744), CGSize(width: 384, height: 416))     // a 2x sheet
        XCTAssertNil(CodexPetAtlas.cellSize(sheetWidth: 1000, sheetHeight: 1000))
        XCTAssertNil(CodexPetAtlas.cellSize(sheetWidth: 1536, sheetHeight: 1536))                                         // right grid, wrong proportions
        XCTAssertNil(CodexPetAtlas.cellSize(sheetWidth: 0, sheetHeight: 0))
    }

    func testStatesMapToTheRowsAndFrameCountsOfTheRealSheet() {
        XCTAssertEqual(CodexPetState.allCases.map(\.row), Array(0..<9))
        XCTAssertEqual(CodexPetState.allCases.map(\.frameCount), [6, 8, 8, 4, 5, 8, 6, 6, 6])      // measured from the sheet: idle, right, left, waving, jumping, failed, waiting, running, review
        XCTAssertTrue(CodexPetState.allCases.allSatisfy { $0.frameCount <= CodexPetAtlas.columns && $0.framesPerSecond > 0 })
        let cell = CGSize(width: 192, height: 208)
        XCTAssertEqual(CodexPetAtlas.cellRect(state: .running, frame: 5, cell: cell), CGRect(x: 960, y: 1456, width: 192, height: 208))
    }

    func testAPetFolderIsLoaded() throws {
        let f = try makeFolder(["pet.json": #"{"id":"gojo-satoru","displayName":"Gojo Satoru","description":"A chibi sorcerer","spritesheetPath":"spritesheet.webp"}"#, "spritesheet.webp": "x"])
        let pet = try XCTUnwrap(PetLibrary.load(folder: f, source: .codex))
        XCTAssertEqual(pet.id, "gojo-satoru"); XCTAssertEqual(pet.name, "Gojo Satoru"); XCTAssertEqual(pet.source, .codex)
        XCTAssertTrue(pet.spritesheet.path.hasSuffix("/gojo/spritesheet.webp"))
    }

    func testDefaultsAndSanitising() throws {
        let f = try makeFolder(["pet.json": #"{}"#, "spritesheet.webp": "x"], name: "my pet!")
        let pet = try XCTUnwrap(PetLibrary.load(folder: f, source: .app))
        XCTAssertEqual(pet.id, "my-pet"); XCTAssertEqual(pet.name, "my-pet")                    // no id or name given: use the folder
        XCTAssertEqual(PetLibrary.sanitizedID("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(PetLibrary.sanitizedID("A b/c"), "A-b-c")
        let png = try makeFolder(["pet.json": #"{"id":"p"}"#, "spritesheet.png": "x"], name: "png")
        XCTAssertTrue(try XCTUnwrap(PetLibrary.load(folder: png, source: .app)).spritesheet.lastPathComponent == "spritesheet.png")
    }

    func testAManifestCannotPointOutsideItsFolder() throws {
        let outsideRoot = FileManager.default.temporaryDirectory.appendingPathComponent("secret-" + UUID().uuidString)
        try Data("x".utf8).write(to: outsideRoot.appendingPathExtension("png"))
        for bad in ["../x.png", "/etc/hosts", "~/x.png", "a/../../x.png", "sheet.txt", "", "sub", outsideRoot.path + ".png"] {
            let f = try makeFolder(["pet.json": "{\"id\":\"p\",\"spritesheetPath\":\"\(bad)\"}", "sheet.webp": "x", "sub/readme.txt": "x"])
            XCTAssertNil(PetLibrary.load(folder: f, source: .app), "should reject: \(bad)")
        }
    }

    func testALinkToAFileOutsideTheFolderIsRejected() throws {
        let f = try makeFolder(["pet.json": #"{"id":"p","spritesheetPath":"link.webp"}"#])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-" + UUID().uuidString + ".webp")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.appendingPathComponent("link.webp"), withDestinationOf: outside)
        XCTAssertNil(PetLibrary.load(folder: f, source: .app))
    }

    func testBrokenPetsAreSkippedAndEarlierFoldersWin() throws {
        let a = try makeFolder(["pet.json": #"{"id":"dup","displayName":"From app"}"#, "spritesheet.webp": "x"], name: "one")
        let b = try makeFolder(["pet.json": #"{"id":"dup","displayName":"From codex"}"#, "spritesheet.webp": "x"], name: "two")
        let broken = a.deletingLastPathComponent().appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("pet.json"))
        let r = PetLibrary.scan([(a.deletingLastPathComponent(), .app), (b.deletingLastPathComponent(), .codex)])
        XCTAssertEqual(r.pets.map(\.name), ["From app"]); XCTAssertEqual(r.skipped, ["broken"])
        XCTAssertNil(PetLibrary.pet(withID: nil, in: r.pets)); XCTAssertEqual(PetLibrary.pet(withID: "dup", in: r.pets)?.source, .app)
    }

    func testSearchDirectoriesFollowCodexHome() {
        let home = URL(fileURLWithPath: "/Users/me"), support = URL(fileURLWithPath: "/Users/me/Library/Application Support/JarvisOS")
        let normal = PetLibrary.searchDirectories(home: home, appSupport: support)
        XCTAssertEqual(normal.map(\.url.path), ["/Users/me/Library/Application Support/JarvisOS/pets", "/Users/me/.codex/pets"]); XCTAssertEqual(normal.map(\.source), [.app, .codex])
        XCTAssertEqual(PetLibrary.searchDirectories(home: home, appSupport: support, environment: ["CODEX_HOME": "/opt/codex"])[1].url.path, "/opt/codex/pets")
        XCTAssertEqual(PetLibrary.searchDirectories(home: home, appSupport: support, environment: ["CODEX_HOME": "  "])[1].url.path, "/Users/me/.codex/pets")
    }

    func testTheSelectedPetSurvivesARestart() throws {
        let suite = UserDefaults(suiteName: "pet-test-\(UUID().uuidString)")!
        var s = FloatingSettings(); s.petID = "gojo-satoru"; s.petSize = 150
        FloatingSettingsStore(defaults: suite).save(s)
        let back = FloatingSettingsStore(defaults: suite).load(); XCTAssertEqual(back.petID, "gojo-satoru"); XCTAssertEqual(back.petSize, 150)
        let bad = try JSONDecoder().decode(FloatingSettings.self, from: Data(#"{"petID":"","petSize":9999}"#.utf8)); XCTAssertNil(bad.petID); XCTAssertEqual(bad.petSize, FloatingSettings.petSizeRange.upperBound)
        XCTAssertNil(FloatingSettings().petID)
    }
}
