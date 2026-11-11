import XCTest
@testable import JarvisCore

/// URLProtocol stub: lets BridgeClient be tested without a network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubProtocol.lastRequest = request
        let (status, data) = StubProtocol.handler?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClientTests: XCTestCase {
    private func client() -> BridgeClient {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [StubProtocol.self]
        return BridgeClient(baseURL: URL(string: "http://127.0.0.1:9999")!, token: "secret-token", session: URLSession(configuration: cfg))
    }

    func testSendsBearerTokenAndDecodesSnakeCase() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"ok":true,"bridge_version":"0.1.0","api_version":"v1","offline_mode":true,"memory_schema":1}"#.utf8)) }
        let h = try await client().health()
        XCTAssertTrue(h.offlineMode)
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }
    func testHTTPErrorsAreTypedWithServerMessage() async {
        StubProtocol.handler = { _ in (404, Data(#"{"detail":"unknown agent"}"#.utf8)) }
        do { _ = try await client().agentTree(); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? BridgeError, .http(status: 404, message: "unknown agent")) }
    }
    func testMalformedBodyIsDecodingErrorNotCrash() async {
        StubProtocol.handler = { _ in (200, Data("<html>nope</html>".utf8)) }
        do { _ = try await client().providers(); XCTFail("expected throw") }
        catch { guard case .decoding = (error as? BridgeError) ?? .notRunning else { return XCTFail("wrong error \(error)") } }
    }
    func testMemorySearchEncodesQueryAndPostsSnakeCaseBodies() async throws {
        StubProtocol.handler = { _ in (200, Data("[]".utf8)) }
        _ = try await client().searchMemory("a b&c=d")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "q=a%20b%26c%3Dd")
        StubProtocol.handler = { _ in (200, Data(#"{"agent":"research","models":["x|y"]}"#.utf8)) }
        try await client().assignModels(agent: "research", models: ["x|y"])
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PUT")
    }
    func testSSEPayloadParsing() {
        XCTAssertEqual(SSE.dataPayload("data: {\"a\":1}"), "{\"a\":1}")
        XCTAssertEqual(SSE.dataPayload("data:{\"a\":1}"), "{\"a\":1}")
        XCTAssertNil(SSE.dataPayload(": keepalive")); XCTAssertNil(SSE.dataPayload("")); XCTAssertNil(SSE.dataPayload("event: x"))
    }
    func testTokenGenerationIsLongAndUnique() {
        let a = BridgeSupervisor.generateToken(), b = BridgeSupervisor.generateToken()
        XCTAssertEqual(a.count, 64); XCTAssertNotEqual(a, b)
    }
    func testPortFinderReturnsUsablePort() {
        let p = PortFinder.freeLoopbackPort(); XCTAssertNotNil(p); XCTAssertGreaterThan(p ?? 0, 1023)
    }
    func testSupervisorReportsMissingPythonHonestly() async {
        let s = BridgeSupervisor()
        await s.start(BridgeLaunchConfig(pythonExecutable: "/nonexistent/python", stateDirectory: URL(fileURLWithPath: "/tmp"), offline: false))
        let st = await s.state
        guard case .failed(let m) = st else { return XCTFail("expected failed, got \(st)") }
        XCTAssertTrue(m.contains("Python not found"))
    }
}
