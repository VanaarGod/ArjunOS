import XCTest
@testable import JarvisCore

final class StoreTests: XCTestCase {
    private func tempStore() throws -> ConversationStore {
        try ConversationStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString)"))
    }
    func testSaveReloadAcrossInstances() throws {
        let s = try tempStore()
        var c = Conversation(title: "Plan", endpoint: "127.0.0.1:11434", model: "llama3.2:3b")
        c.messages = [ChatMessage(role: "user", content: "hello"), ChatMessage(role: "assistant", content: "hi", model: "llama3.2:3b")]
        try s.save(c)
        let reopened = try ConversationStore(directory: s.directory)           // simulates app restart
        let loaded = try XCTUnwrap(reopened.load(c.id))
        XCTAssertEqual(loaded.messages.map(\.content), ["hello", "hi"]); XCTAssertEqual(loaded.model, "llama3.2:3b")
    }
    func testTemporaryConversationsAreNeverWritten() throws {
        let s = try tempStore(); try s.save(Conversation(title: "tmp", temporary: true))
        XCTAssertTrue(s.loadAll().isEmpty)
    }
    func testCorruptFileIsQuarantinedNotFatal() throws {
        let s = try tempStore(); let id = UUID()
        try Data("{broken".utf8).write(to: s.directory.appendingPathComponent("\(id.uuidString).json"))
        XCTAssertNil(s.load(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.directory.appendingPathComponent("\(id.uuidString).json.corrupt").path))
    }
    func testSearchDeleteAndExport() throws {
        let s = try tempStore()
        var a = Conversation(title: "Taxes"); a.messages = [ChatMessage(role: "user", content: "deduction rules")]
        let b = Conversation(title: "Recipes"); try s.save(a); try s.save(b)
        XCTAssertEqual(s.search("DEDUCTION").map(\.title), ["Taxes"])
        try s.delete(a.id); XCTAssertNil(s.load(a.id))
        XCTAssertTrue(ConversationStore.exportMarkdown(a).contains("# Taxes"))
    }
    func testDirectoryIsOwnerOnly() throws {
        let s = try tempStore()
        let perms = try FileManager.default.attributesOfItem(atPath: s.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }
    func testAttachmentsSurviveSaveAndReload() throws {
        let s = try tempStore()
        var user = ChatMessage(role: "user", content: "what is in these?")
        user.attachments = [Attachment(name: "résumé \"v2\".pdf", kind: "pdf", bytes: 1234, text: "Línea 1\nTab\there \u{1F600} \\ \"quoted\"", note: "Only the first 600,000 characters were kept.", chars: 700_000),
                            Attachment(name: "cat.jpg", kind: "image", bytes: 99, imageBase64: "QUJDRA==")]
        var c = Conversation(title: "files"); c.messages = [user]
        try s.save(c)
        let loaded = try XCTUnwrap(ConversationStore(directory: s.directory).load(c.id))
        let a = try XCTUnwrap(loaded.messages.first?.attachments)
        XCTAssertEqual(a.count, 2); XCTAssertEqual(a[0].name, "résumé \"v2\".pdf"); XCTAssertEqual(a[0].text, user.attachments?[0].text)
        XCTAssertEqual(a[0].chars, 700_000); XCTAssertEqual(a[1].imageBase64, "QUJDRA==")
    }
    func testMessagesSavedBeforeAttachmentsExistedStillLoad() throws {
        let s = try tempStore(); let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","title":"old","createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z","temporary":false,"messages":[{"id":"6E7C1B3A-0000-4000-8000-000000000001","role":"user","content":"hi","createdAt":"2026-10-01T10:00:00Z"}]}"#
        try Data(old.utf8).write(to: s.directory.appendingPathComponent("\(id.uuidString).json"))
        let c = try XCTUnwrap(s.load(id)); XCTAssertEqual(c.messages.first?.content, "hi"); XCTAssertNil(c.messages.first?.attachments)
    }

    func testSummariesHaveNoMessagesAndSurviveRestart() throws {
        let s = try tempStore()
        var a = Conversation(title: "Taxes", model: "m"); a.messages = [ChatMessage(role: "user", content: "deduction rules")]
        let b = Conversation(title: "Recipes"); try s.save(a); try s.save(b)
        let first = s.loadSummaries()
        XCTAssertEqual(Set(first.map(\.title)), ["Taxes", "Recipes"])
        XCTAssertTrue(first.allSatisfy { $0.messages.isEmpty })
        let reopened = try ConversationStore(directory: s.directory)             // second launch reads the cache
        let second = reopened.loadSummaries()
        XCTAssertEqual(second.map(\.id), first.map(\.id)); XCTAssertEqual(second.first { $0.title == "Taxes" }?.model, "m")
        XCTAssertEqual(reopened.loadAll().count, 2)                              // the cache file is not mistaken for a conversation
    }
    func testSummariesNoticeChangedAndDeletedFiles() throws {
        let s = try tempStore()
        var a = Conversation(title: "Old title"); try s.save(a); _ = s.loadSummaries()
        a.title = "New title"; a.messages = [ChatMessage(role: "user", content: "a longer body so the size changes")]; try s.save(a)
        XCTAssertEqual(s.loadSummaries().first?.title, "New title")
        try s.delete(a.id)
        XCTAssertTrue(s.loadSummaries().isEmpty)
    }
    func testSearchIDsFindsMessageText() throws {
        let s = try tempStore()
        var a = Conversation(title: "Taxes"); a.messages = [ChatMessage(role: "user", content: "Deduction rules")]
        let b = Conversation(title: "Recipes"); try s.save(a); try s.save(b)
        XCTAssertEqual(s.searchIDs("deduction"), [a.id]); XCTAssertTrue(s.searchIDs("").isEmpty)
    }
}
