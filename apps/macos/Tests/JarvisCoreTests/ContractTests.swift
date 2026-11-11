import XCTest
@testable import JarvisCore

/// Decodes fixtures generated from the REAL Python bridge (scripts/gen_fixtures.py) to catch contract drift.
final class ContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"), "missing fixture \(name)")
        return try Data(contentsOf: url)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(T.self, from: fixture(name))
    }

    func testHealth() throws {
        let h = try decode(BridgeHealth.self, "health")
        XCTAssertTrue(h.ok); XCTAssertEqual(h.apiVersion, "v1"); XCTAssertFalse(h.offlineMode)
        XCTAssertEqual(h.pdfSupport, true); XCTAssertNotNil(h.python)
    }
    func testProvidersAreValidatedOllama() throws {
        let p = try decode([Provider].self, "providers")
        XCTAssertEqual(p.count, 1); XCTAssertEqual(p[0].kind, "ollama"); XCTAssertTrue(p[0].isUsable)
        XCTAssertEqual(p[0].models, ["llama3.2:3b", "qwen2.5-coder:7b"])
    }
    func testModelsKeepUnknownCapabilitiesNil() throws {
        let m = try decode([ModelEntry].self, "models")
        let llama = try XCTUnwrap(m.first { $0.modelID == "llama3.2:3b" })
        XCTAssertEqual(llama.capabilities?.tools, true); XCTAssertEqual(llama.contextLength, 8192)
        XCTAssertNil(llama.capabilities?.vision, "unknown capability must stay nil, never false")
        XCTAssertTrue(llama.id.hasSuffix("|llama3.2:3b"), "identity must include the endpoint")
    }
    func testMemorySearchWithMixedWhyPayload() throws {
        let h = try decode([MemoryHit].self, "memory_search")
        XCTAssertEqual(h[0].memory.content, "prefers metric units"); XCTAssertEqual(h[0].memory.status, "confirmed")
        XCTAssertNotNil(h[0].why["lexical"]); XCTAssertEqual(h[0].why["source"]?.description, "user")
    }
    func testMemoryListNeedsNoSearch() throws {
        let m = try decode([MemoryRecord].self, "memory_list")
        XCTAssertEqual(m.count, 1); XCTAssertEqual(m[0].content, "prefers metric units"); XCTAssertEqual(m[0].status, "confirmed")
    }
    func testProfileDecodesAndReportsItsCost() throws {
        let p = try decode(UserProfile.self, "profile")
        XCTAssertEqual(p.callMe, "Arjun"); XCTAssertTrue(p.onboarded); XCTAssertTrue(p.include)
        XCTAssertEqual(p.directness, "direct"); XCTAssertEqual(p.length, "brief"); XCTAssertEqual(p.maxChars, 1600)
        XCTAssertTrue(p.compiled.hasPrefix("User: Arjun.")); XCTAssertEqual(p.tokens, 38); XCTAssertEqual(p.limits["instructions"], 1200)
        XCTAssertEqual(p.choices["length"], ["brief", "balanced", "detailed"])
    }
    func testProfileUpdateSendsOnlyWhatChanged() throws {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase
        let json = try JSONSerialization.jsonObject(with: e.encode(ProfileUpdate(callMe: "AJ", onboarded: true))) as? [String: Any]
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), ["call_me", "onboarded"])
    }
    func testApprovalArgsDecodeAllJSONKinds() throws {
        let a = try decode([Approval].self, "approvals")
        XCTAssertEqual(a[0].tool, "mcp:x/send"); XCTAssertEqual(a[0].args["to"]?.description, "a@b.c")
        XCTAssertEqual(a[0].args["n"]?.description, "3"); XCTAssertEqual(a[0].args["ok"]?.description, "true")
    }
    func testAgentTreeHasJarvisRootAndEightSpecialists() throws {
        let t = try decode([AgentNode].self, "agent_tree")
        XCTAssertEqual(t[0].id, "jarvis"); XCTAssertEqual(t[0].children.count, 8)
    }
    func testAgentRunAndTrace() throws {
        let r = try decode(RunResult.self, "agent_run")
        XCTAssertEqual(r.state, "succeeded"); XCTAssertEqual(r.tokens.completion, 4)
        XCTAssertEqual(r.trace.map(\.kind), ["requested", "model_attempt", "completed"]); XCTAssertFalse(r.degraded)
    }
    func testSettingsDefaultsAndActiveFlag() throws {
        let st = try decode(AppSettings.self, "settings")
        XCTAssertEqual(st.webSearchMode, "auto"); XCTAssertTrue(st.webSearchConsented); XCTAssertTrue(st.webSearchActive)
        XCTAssertEqual(st.webSearchMaxResults, 5); XCTAssertTrue(st.memoryAutoInject)
        XCTAssertEqual(st.readPaths, true)                                  // files named by path are read unless switched off
    }
    func testSearchChatStreamDecodesAndReducesToAnAnswerWithSources() throws {
        let events = try decode([ChatEvent].self, "chat_events_search")
        var msg = ChatMessage(role: "assistant", content: "", model: "llama3.2:3b")
        var outcomes: [ChatOutcome] = []
        for e in events { outcomes.append(ChatReducer.apply(e, to: &msg)) }
        XCTAssertEqual(msg.content, "Hello from mock Ollama")
        let search = try XCTUnwrap(msg.activity?.first { $0.kind == "search" })
        XCTAssertEqual(search.status, "done"); XCTAssertEqual(search.links.count, 2)
        XCTAssertEqual(search.links.first?.url, "https://example.com/a?x=1")
        XCTAssertEqual(msg.activity?.count, 1, "running + done must collapse into ONE activity")
        XCTAssertEqual(outcomes.last, .finished)
        let last = try XCTUnwrap(events.last); XCTAssertEqual(last.completionTokens, 4, "token counts must stay integers, never redacted strings")
    }
    func testRememberChatStreamProducesAMemorySavedActivity() throws {
        let events = try decode([ChatEvent].self, "chat_events_memory")
        var msg = ChatMessage(role: "assistant", content: "")
        for e in events { _ = ChatReducer.apply(e, to: &msg) }
        let saved = try XCTUnwrap(msg.activity?.first { $0.kind == "memory_saved" })
        XCTAssertNotNil(saved.memoryID); XCTAssertFalse((saved.detail ?? "").isEmpty)
    }
    func testMCPServersDecodeWithoutRewritingConfigKeys() throws {
        let servers = try decode([MCPServer].self, "mcp_servers")
        let calc = try XCTUnwrap(servers.first { $0.name == "calc" })
        XCTAssertEqual(calc.state, "ready"); XCTAssertTrue(calc.approved)
        XCTAssertTrue(calc.tools.contains { $0.name == "add" && $0.trusted }); XCTAssertTrue(calc.tools.contains { $0.name == "echo" && !$0.trusted })
        let files = try XCTUnwrap(servers.first { $0.name == "files" })
        XCTAssertEqual(files.state, "disconnected"); XCTAssertFalse(files.approved)
        XCTAssertEqual(files.envNames, ["API_TOKEN"]); XCTAssertFalse(files.warnings.isEmpty)
        XCTAssertTrue(try XCTUnwrap(files.configText).contains("\"API_TOKEN\""), "env names must survive exactly (no snake/camel conversion)")
    }
    func testFileExtractResponseDecodes() throws {
        let f = try decode(ExtractedFile.self, "file_extract")
        XCTAssertEqual(f.name, "manual.txt"); XCTAssertEqual(f.kind, "text"); XCTAssertEqual(f.text, "Warranty: 36 months.\n")
        XCTAssertEqual(f.chars, 21); XCTAssertFalse(f.truncated); XCTAssertNil(f.warning)
    }
    func testChatStreamWithAFileReducesToAReadFileActivity() throws {
        let events = try decode([ChatEvent].self, "chat_events_files")
        var msg = ChatMessage(role: "assistant", content: "")
        for e in events { _ = ChatReducer.apply(e, to: &msg) }
        let a = try XCTUnwrap(msg.activity?.first { $0.kind == "files" })
        XCTAssertEqual(a.title, "Read 1 file"); XCTAssertTrue(a.detail?.contains("manual.txt") == true); XCTAssertTrue(a.detail?.contains("read in full") == true)
        XCTAssertEqual(msg.content, "Hello from mock Ollama")
    }
    func testSettingsIncludeTheAttachmentBudget() throws {
        XCTAssertEqual(try decode(AppSettings.self, "settings").attachmentContextChars, 12000)
    }
    func testShellStatusDecodes() throws {
        let st = try decode(ShellStatus.self, "shell_status")
        XCTAssertTrue(st.enabled); XCTAssertTrue(st.javascriptReady); XCTAssertEqual(st.sandbox, "seatbelt")
        XCTAssertTrue(st.allowed.contains("node")); XCTAssertFalse(st.allowed.contains("rm")); XCTAssertFalse(st.allowed.contains("sudo"))
    }
    func testSettingsCarryTheTerminalSwitch() throws {
        XCTAssertEqual(try decode(AppSettings.self, "settings").shellEnabled, true)
    }
    func testTerminalChatStreamReducesToOneCommandActivityWithOutput() throws {
        let events = try decode([ChatEvent].self, "chat_events_shell")
        var m = ChatMessage(role: "assistant", content: "")
        var sawApproval = false
        for e in events { if case .approvalNeeded = ChatReducer.apply(e, to: &m) { sawApproval = true } }
        XCTAssertTrue(sawApproval)
        XCTAssertEqual(m.activity?.count, 1, "waiting, running and done are one chip, not three")
        let a = try XCTUnwrap(m.activity?.first)
        XCTAssertEqual(a.kind, "shell"); XCTAssertEqual(a.title, "Ran command"); XCTAssertEqual(a.detail, "echo hello")
        XCTAssertEqual(a.exitCode, 0); XCTAssertTrue(a.output?.contains("hello") == true)
    }
}
