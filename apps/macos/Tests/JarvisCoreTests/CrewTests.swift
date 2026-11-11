import XCTest
@testable import JarvisCore

/// Decodes a REAL event stream captured from the Python crew engine (Fixtures/crew_events.jsonl), so a renamed field fails here.
final class CrewTests: XCTestCase {
    private func events() throws -> [CrewEvent] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "crew_events", withExtension: "jsonl", subdirectory: "Fixtures"))
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try d.decode(CrewEvent.self, from: Data($0.utf8)) }
    }

    func testEveryEventInARealRunDecodes() throws {
        let ev = try events()
        XCTAssertGreaterThan(ev.count, 20)
        XCTAssertEqual(ev.last?.done, true)
    }

    func testPlanStartAndMemory() throws {
        let ev = try events()
        let start = try XCTUnwrap(ev.compactMap(\.start).first)
        XCTAssertTrue(start.plan.feasible); XCTAssertEqual(start.plan.mode, "swap")
        XCTAssertGreaterThan(start.plan.budget, 0)
        let plan = try XCTUnwrap(ev.compactMap(\.plan).first)
        XCTAssertEqual(plan.subtasks.map(\.id), ["w1", "w2"]); XCTAssertEqual(plan.subtasks[0].inputs, ["doc1.pdf"])
        XCTAssertEqual(plan.conventions, ["Dates as YYYY-MM-DD"])
        let mem = try XCTUnwrap(ev.compactMap(\.memory).last)
        XCTAssertGreaterThan(mem.total, 0); XCTAssertTrue(["normal", "warn", "critical"].contains(mem.pressure))
        XCTAssertEqual(mem.mode, "swap"); XCTAssertFalse((mem.loaded ?? []).isEmpty)
    }

    func testTeamTalkAndEscalationEvents() throws {
        let ev = try events()
        XCTAssertEqual(ev.compactMap(\.question).first?.from, "w1")
        let nu = try XCTUnwrap(ev.compactMap(\.needsUser).first)
        XCTAssertEqual(nu.kind, "boss_needs_user"); XCTAssertTrue(nu.question.contains("2023"))
        XCTAssertEqual(ev.compactMap(\.answer).first?.text, "2023")
        XCTAssertEqual(ev.compactMap(\.shared).first?.key, "currency")
        XCTAssertEqual(ev.compactMap(\.agentProblem).first?.attempt, 1)
        let b = try XCTUnwrap(ev.compactMap(\.browse).first)
        XCTAssertEqual(b.agent, "w2"); XCTAssertEqual(b.url, "https://example.com")
    }

    func testWorkerChatEventsFeedTheNormalChatReducer() throws {
        let ev = try events()
        var msg = ChatMessage(role: "assistant", content: "")
        for e in ev where e.agent == "w1" { if let inner = e.ev { _ = ChatReducer.apply(inner, to: &msg) } }
        XCTAssertTrue(msg.content.contains("Report one."))
        XCTAssertFalse(msg.content.contains("<ask_boss"), "a team request must never show up as the worker's answer")
    }

    func testResultsAndFinal() throws {
        let ev = try events()
        let results = ev.compactMap(\.result)
        XCTAssertEqual(Set(results.map(\.id)), ["w1", "w2"]); XCTAssertTrue(results.allSatisfy { !$0.summary.isEmpty })
        let f = try XCTUnwrap(ev.compactMap(\.final).first)
        XCTAssertEqual(f.text, "The combined answer."); XCTAssertTrue(f.context.contains("doc1.pdf")); XCTAssertEqual(f.reports.count, 2)
        XCTAssertEqual(ev.compactMap(\.ping).count, 1)
    }

    func testRequestUsesTheWireNames() throws {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase
        let req = CrewRequest(task: "t", boss: "a|b", workerModel: "a|c", inputs: [.init(name: "x.pdf", kind: "pdf", text: "hi", imagesB64: ["AAA"], workerModel: "a|v")], preference: "one_at_a_time", maxWorkers: 2)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: e.encode(req)) as? [String: Any])
        XCTAssertEqual(j["worker_model"] as? String, "a|c"); XCTAssertEqual(j["max_workers"] as? Int, 2); XCTAssertEqual(j["ui_browser"] as? Bool, true)
        let input = try XCTUnwrap((j["inputs"] as? [[String: Any]])?.first)
        XCTAssertEqual(input["images_b64"] as? [String], ["AAA"]); XCTAssertEqual(input["worker_model"] as? String, "a|v")
    }

    func testByteFormatting() {
        XCTAssertEqual(crewBytes(9_663_676_416), "9.0 GB"); XCTAssertEqual(crewBytes(48 * 1_073_741_824), "48 GB"); XCTAssertEqual(crewBytes(300 * 1_048_576), "300 MB")
        XCTAssertEqual(crewModelName("127.0.0.1:11434|qwen2.5:7b"), "qwen2.5:7b")
    }
}
