import XCTest
@testable import JarvisCore

final class BrowserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"), "missing fixture \(name)")
        return try Data(contentsOf: url)
    }
    private func url(_ t: BrowserTarget) -> String? { if case .url(let u) = t { return u.absoluteString } else { return nil } }
    private func searchURL(_ t: BrowserTarget) -> String? { if case .search(let u) = t { return u.absoluteString } else { return nil } }
    private func isBlocked(_ t: BrowserTarget) -> Bool { if case .blocked = t { return true } else { return false } }

    // MARK: address bar
    func testAddressesGetHttps() {
        XCTAssertEqual(url(BrowserURL.resolve("example.com")), "https://example.com")
        XCTAssertEqual(url(BrowserURL.resolve("  www.apple.com/mac  ")), "https://www.apple.com/mac")
        XCTAssertEqual(url(BrowserURL.resolve("https://example.com/a?b=c")), "https://example.com/a?b=c")
        XCTAssertEqual(url(BrowserURL.resolve("HTTP://Example.com"))?.lowercased(), "http://example.com")
    }
    func testLocalAddressesStayHttp() {
        XCTAssertEqual(url(BrowserURL.resolve("localhost:11434")), "http://localhost:11434")
        XCTAssertEqual(url(BrowserURL.resolve("192.168.1.10:8080/x")), "http://192.168.1.10:8080/x")
    }
    func testAnythingElseIsASearch() throws {
        let s = try XCTUnwrap(searchURL(BrowserURL.resolve("best laptop 2026")))
        XCTAssertTrue(s.hasPrefix("https://duckduckgo.com/?q=best")); XCTAssertFalse(s.contains(" "))
        XCTAssertNotNil(searchURL(BrowserURL.resolve("what is 3.5 plus 2")))
        XCTAssertNotNil(searchURL(BrowserURL.resolve("e.g.")))
        XCTAssertNotNil(searchURL(BrowserURL.resolve("hello")))
    }
    func testDangerousSchemesAreRefusedNotSearched() {
        for s in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,<script>1</script>", "view-source:https://x.com", "about:blank", "ftp://example.com", "ssh://host"] {
            XCTAssertTrue(isBlocked(BrowserURL.resolve(s)), s)
        }
        XCTAssertTrue(isBlocked(BrowserURL.resolve("   ")))
    }

    // MARK: payload
    func testPayloadDecodesLeniently() throws {
        let json = #"{"url":"https://x.com","title":"T","text":"hello","prices":[{"text":"$5"}],"meta":{"og:site_name":"X"},"scroll":{"percent":40},"junk":[1,2],"tables":"oops"}"#
        let p = try JSONDecoder().decode(PagePayload.self, from: Data(json.utf8))
        XCTAssertEqual(p.url, "https://x.com"); XCTAssertEqual(p.text, "hello"); XCTAssertEqual(p.prices.first?.text, "$5")
        XCTAssertEqual(p.meta["og:site_name"], "X", "colon keys must survive"); XCTAssertEqual(p.scroll?["percent"], 40)
        XCTAssertEqual(p.status, "ready"); XCTAssertTrue(p.tables.isEmpty); XCTAssertEqual(p.source, "dom")
    }
    func testEmptyObjectIsAValidPayload() throws {
        let p = try JSONDecoder().decode(PagePayload.self, from: Data("{}".utf8))
        XCTAssertTrue(p.isBlank); XCTAssertEqual(p.contentCount, 0)
    }
    /// Every key the app sends must be a field the bridge accepts (the field list is generated from the real Python model).
    func testEncodedKeysAreAllKnownToTheBridge() throws {
        let known = Set(try JSONDecoder().decode([String].self, from: fixture("page_in_fields")))
        var p = PagePayload(url: "https://x.com", title: "T"); p.tabID = "t1"; p.statusDetail = "d"; p.lang = "en"; p.canonical = "https://x.com"
        p.meta = ["a": "b"]; p.structured = [.object(["@type": .string("Product")])]; p.prices = [.init(text: "$1", label: "Price")]
        p.specs = [.init(name: "n", value: "v")]; p.headings = ["h"]; p.tables = [[["a"]]]; p.text = "t"; p.visibleText = "v"; p.selection = "s"
        p.ocrText = "o"; p.links = [.init(text: "l", href: "https://x.com")]; p.scroll = ["percent": 10]; p.notes = ["n"]; p.capturedAt = "now"
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase                       // the client's real encoder
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: e.encode(p)) as? [String: Any])
        XCTAssertTrue(Set(sent.keys).isSubset(of: known), "unknown keys: \(Set(sent.keys).subtracting(known))")
        for k in ["tab_id", "status_detail", "visible_text", "ocr_text", "captured_at"] { XCTAssertNotNil(sent[k], k) }
    }
    func testPageEventsFromTheBridgeDecode() throws {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let events = try d.decode([ChatEvent].self, from: fixture("chat_events_page"))
        var m = ChatMessage(role: "assistant", content: "")
        for e in events { _ = ChatReducer.apply(e, to: &m) }
        let a = try XCTUnwrap(m.activity?.first { $0.kind == "page" })
        XCTAssertEqual(a.title, "Used the open page"); XCTAssertTrue(a.detail?.contains("shop.example.com") == true); XCTAssertTrue(a.detail?.contains("product data") == true)
        XCTAssertEqual(m.content, "On the page: $19.99.")
    }
    func testUnreadablePageIsNotReportedAsUsed() throws {
        var m = ChatMessage(role: "assistant", content: "")
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let ev = try d.decode(ChatEvent.self, from: Data(#"{"page_used":{"title":"T","url":"https://x.com","host":"x.com","used_chars":0,"total_chars":0,"excerpted":false,"source":"dom","status":"restricted","structured":false,"prices":0,"ocr":false}}"#.utf8))
        _ = ChatReducer.apply(ev, to: &m)
        XCTAssertEqual(m.activity?.first?.title, "Open page"); XCTAssertTrue(m.activity?.first?.detail?.contains("couldn't read it") == true)
    }
}
