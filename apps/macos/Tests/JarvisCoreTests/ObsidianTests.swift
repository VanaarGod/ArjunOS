import XCTest
@testable import JarvisCore

final class ObsidianTests: XCTestCase {
    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }

    func testStatusAndSyncReportDecodeFromTheBridge() throws {
        let json = """
        {"enabled":true,"configured":true,"active":true,"vault_path":"/Users/a/Vault","vault_name":"Vault","issue":null,"notes":42,"chunks":300,
         "agent_folder":"ArjunOS","memories_folder":"ArjunOS/Memories","fts":true,"last_index":1.7e9,
         "last_sync":{"written":2,"imported":1,"memory_updated":0,"note_updated":1,"notes_deleted":0,"memories_deleted":0,"warnings":["careful"],"at":1.7e9}}
        """
        let s = try decoder().decode(ObsidianStatus.self, from: Data(json.utf8))
        XCTAssertTrue(s.active); XCTAssertEqual(s.vaultName, "Vault"); XCTAssertEqual(s.memoriesFolder, "ArjunOS/Memories")
        XCTAssertEqual(s.lastSync?.changes, 4); XCTAssertEqual(s.lastSync?.warnings, ["careful"])
    }

    func testSearchNoteAndRecentDecode() throws {
        let hit = try decoder().decode([VaultHit].self, from: Data(#"[{"path":"A/B.md","title":"B","heading":"Goals","excerpt":"x","score":1.5,"tags":["work"]}]"#.utf8))
        XCTAssertEqual(hit.first?.id, "A/B.md#Goals")
        let note = try decoder().decode(VaultNote.self, from: Data(#"{"path":"B.md","title":"B","tags":[],"aliases":["b"],"body":"hi","truncated":false,"links":[{"name":"C","path":null}],"backlinks":["A.md"],"mtime":1.0,"agent_note":true}"#.utf8))
        XCTAssertTrue(note.agentNote); XCTAssertNil(note.links[0].path)
        let recent = try decoder().decode(VaultRecent.self, from: Data(#"{"notes":[{"rel":"A.md","title":"A","mtime":2.0,"tags":["t"]}],"tags":[{"tag":"t","count":3}]}"#.utf8))
        XCTAssertEqual(recent.tags.first?.count, 3)
    }

    func testObsidianLinksAreEncodedAndOpenTheRightNote() {
        let url = ObsidianLinks.openURL(vaultName: "My Vault", path: "Projects/Espresso & Co.md")
        XCTAssertEqual(url?.absoluteString, "obsidian://open?vault=My%20Vault&file=Projects%2FEspresso%20%26%20Co")
        XCTAssertEqual(ObsidianLinks.path(fromChipURL: ObsidianLinks.chipURL("A/B.md")), "A/B.md"); XCTAssertNil(ObsidianLinks.path(fromChipURL: "https://x.com"))
    }

    func testChatEventsBecomeChipsAndMergeNotes() throws {
        var msg = ChatMessage(role: "assistant", content: "")
        let d = decoder()
        _ = ChatReducer.apply(try d.decode(ChatEvent.self, from: Data(#"{"vault_used":[{"path":"A.md","title":"A","heading":"Goals"}]}"#.utf8)), to: &msg)
        _ = ChatReducer.apply(try d.decode(ChatEvent.self, from: Data(#"{"vault_used":[{"path":"A.md","title":"A"},{"path":"B/C.md","title":"C"}]}"#.utf8)), to: &msg)
        let used = try XCTUnwrap(msg.activity?.first { $0.kind == "vault_used" })
        XCTAssertEqual(used.title, "Used 2 notes from Obsidian"); XCTAssertEqual(used.links.map(\.title), ["A", "C"])        // A is not listed twice
        XCTAssertEqual(ObsidianLinks.path(fromChipURL: used.links[1].url), "B/C.md")
        _ = ChatReducer.apply(try d.decode(ChatEvent.self, from: Data(#"{"vault_saved":{"path":"ArjunOS/Notes/Plan.md","title":"Plan"}}"#.utf8)), to: &msg)
        let saved = try XCTUnwrap(msg.activity?.first { $0.kind == "vault_saved" })
        XCTAssertEqual(saved.path, "ArjunOS/Notes/Plan.md"); XCTAssertEqual(saved.detail, "Plan")
    }
}
