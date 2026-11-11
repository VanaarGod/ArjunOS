import XCTest
@testable import JarvisCore

final class ReducerTests: XCTestCase {
    private func fresh() -> ChatMessage { ChatMessage(role: "assistant", content: "") }
    private func ev(_ json: String) throws -> ChatEvent {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(ChatEvent.self, from: Data(json.utf8))
    }

    func testDeltasAccumulateAndDoneFinishes() throws {
        var m = fresh()
        XCTAssertEqual(ChatReducer.apply(try ev(#"{"delta":"Hel"}"#), to: &m), .none)
        XCTAssertEqual(ChatReducer.apply(try ev(#"{"delta":"lo"}"#), to: &m), .none)
        XCTAssertEqual(ChatReducer.apply(try ev(#"{"done":true,"prompt_tokens":3,"completion_tokens":2}"#), to: &m), .finished)
        XCTAssertEqual(m.content, "Hello"); XCTAssertNil(m.activity)
    }
    func testErrorEventSurfacesAsFailure() throws {
        var m = fresh()
        XCTAssertEqual(ChatReducer.apply(try ev(#"{"error":{"kind":"not_found","message":"no such model"}}"#), to: &m), .failed("not_found: no such model"))
    }
    func testSearchRunningThenDoneIsOneActivityAndErrorsAreShown() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":1,"name":"web_search","query":"cats","status":"running"}}"#), to: &m)
        XCTAssertEqual(m.activity?.first?.status, "running"); XCTAssertEqual(m.activity?.first?.detail, "cats")
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":1,"name":"web_search","query":"cats","status":"error","error":"DuckDuckGo returned HTTP 429."}}"#), to: &m)
        XCTAssertEqual(m.activity?.count, 1); XCTAssertEqual(m.activity?.first?.status, "error"); XCTAssertTrue(m.activity?.first?.detail?.contains("429") == true)
    }
    func testTwoSearchesAreTwoActivities() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":1,"name":"web_search","query":"a","status":"done","results":[]}}"#), to: &m)
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":2,"name":"web_search","query":"b","status":"done","results":[]}}"#), to: &m)
        XCTAssertEqual(m.activity?.count, 2)
    }
    func testMCPToolLifecycleAndApprovalOutcome() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":null,"name":"calc.add","status":"waiting_approval","args":{"a":2}}}"#), to: &m)
        XCTAssertTrue(m.activity?.first?.title.contains("approval") == true)
        XCTAssertEqual(ChatReducer.apply(try ev(#"{"approval":{"id":"appr_1","tool":"calc.add","args":{"a":2}}}"#), to: &m), .approvalNeeded("appr_1"))
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":null,"name":"calc.add","status":"done"}}"#), to: &m)
        XCTAssertEqual(m.activity?.count, 1); XCTAssertEqual(m.activity?.first?.title, "Used calc.add")
    }
    func testMemoryEventsAndPluralisation() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"memory_used":[{"id":"mem_1","content":"dog is Max"}]}"#), to: &m)
        XCTAssertEqual(m.activity?.first?.title, "Used 1 memory")
        _ = ChatReducer.apply(try ev(#"{"memory_used":[{"id":"a","content":"x"},{"id":"b","content":"y"}]}"#), to: &m)
        XCTAssertEqual(m.activity?.count, 1); XCTAssertEqual(m.activity?.first?.title, "Used 2 memories")
        _ = ChatReducer.apply(try ev(#"{"memory_saved":{"id":"mem_9","content":"likes tea","category":"preference"}}"#), to: &m)
        XCTAssertEqual(m.activity?.last?.memoryID, "mem_9")
        _ = ChatReducer.apply(try ev(#"{"memory_used":[]}"#), to: &m)
        XCTAssertEqual(m.activity?.count, 2, "an empty memory_used must not add a chip")
    }
    func testNoticesAccumulate() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"notice":"one"}"#), to: &m); _ = ChatReducer.apply(try ev(#"{"notice":"two"}"#), to: &m)
        XCTAssertEqual(m.activity?.map(\.title), ["one", "two"])
    }
    func testOlderSavedMessagesWithoutActivityStillDecode() throws {
        let old = #"{"id":"6E7C1B3A-0000-4000-8000-000000000001","role":"user","content":"hi","createdAt":"2026-10-01T10:00:00Z"}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let m = try d.decode(ChatMessage.self, from: Data(old.utf8))
        XCTAssertEqual(m.content, "hi"); XCTAssertNil(m.activity)
    }
    func testActivityRoundTripsThroughSavedConversation() throws {
        var m = ChatMessage(role: "assistant", content: "x")
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":1,"name":"web_search","query":"q","status":"done","results":[{"title":"T","url":"https://a.example","snippet":"s"}]}}"#), to: &m)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(ChatMessage.self, from: try e.encode(m))
        XCTAssertEqual(back.activity?.first?.links.first?.url, "https://a.example")
    }

    func testFilesUsedDistinguishesExcerptsFromFullReads() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"files_used":[{"name":"big.pdf","used_chars":4097,"total_chars":24648,"excerpted":true},{"name":"small.txt","used_chars":18,"total_chars":18,"excerpted":false}]}"#), to: &m)
        let a = try XCTUnwrap(m.activity?.first)
        XCTAssertEqual(a.title, "Read 2 files")
        let lines = (a.detail ?? "").split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("big.pdf") && lines[0].contains("excerpts"), "a truncated read must be disclosed, never presented as a full read")
        XCTAssertTrue(lines[1].contains("small.txt") && lines[1].contains("read in full"))
    }
    func testEmptyFilesUsedAddsNoChip() throws {
        var m = fresh(); _ = ChatReducer.apply(try ev(#"{"files_used":[]}"#), to: &m); XCTAssertNil(m.activity)
    }
    func testShellRefusedBeforeApprovalIsShownAsNotRun() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":2,"name":"shell","args":{"command":"rm -rf x"},"status":"error","error":"deleting files is never allowed"}}"#), to: &m)
        let a = try XCTUnwrap(m.activity?.first)
        XCTAssertEqual(a.title, "Command not run"); XCTAssertEqual(a.detail, "rm -rf x"); XCTAssertEqual(a.output, "deleting files is never allowed"); XCTAssertNil(a.exitCode)
    }
    func testShellNonZeroExitIsAFailureWithOutput() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":1,"name":"shell","args":{"command":"cat nope"},"status":"error","exit_code":1,"output":"exit code: 1\nstderr:\nno such file"}}"#), to: &m)
        let a = try XCTUnwrap(m.activity?.first)
        XCTAssertEqual(a.title, "Command failed"); XCTAssertEqual(a.exitCode, 1); XCTAssertTrue(a.output?.contains("no such file") == true)
    }

    func testCreatedFileBecomesOneChipWithPathAndPreview() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":3,"name":"file","args":{"name":"notes.md"},"status":"running"}}"#), to: &m)
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":3,"name":"file","args":{"name":"notes.md","path":"/w/notes.md"},"status":"done","output":"# Hi"}}"#), to: &m)
        XCTAssertEqual(m.activity?.count, 1)
        let a = try XCTUnwrap(m.activity?.first)
        XCTAssertEqual(a.kind, "file"); XCTAssertEqual(a.title, "Created file"); XCTAssertEqual(a.detail, "notes.md"); XCTAssertEqual(a.path, "/w/notes.md"); XCTAssertEqual(a.output, "# Hi")
    }
    func testFailedFileShowsTheReason() throws {
        var m = fresh()
        _ = ChatReducer.apply(try ev(#"{"tool":{"id":1,"name":"file","args":{"name":"x.exe"},"status":"error","error":"'.exe' files can't be created here"}}"#), to: &m)
        XCTAssertEqual(m.activity?.first?.title, "Couldn't create file"); XCTAssertTrue(m.activity?.first?.output?.contains(".exe") == true)
    }
    func testThinkingAndHeartbeatEventsDecodeAndDoNotTouchTheMessage() throws {
        var m = fresh()
        XCTAssertEqual(ChatReducer.apply(try ev(#"{"thinking":true}"#), to: &m), .thinking)
        XCTAssertEqual(ChatReducer.apply(try ev(#"{"ping":true}"#), to: &m), .none)
        XCTAssertEqual(m.content, ""); XCTAssertNil(m.activity)
    }
}
