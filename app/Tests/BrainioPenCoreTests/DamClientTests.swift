import XCTest
@testable import BrainioPenCore

/// The client is the only thing between a page and somebody else's server, so what is tested here
/// is the wire: the shape sent, the shape understood, and a refusal told apart from a missing file.
final class DamClientTests: XCTestCase {
    private let account = DamAccount(host: "https://dam.example.com/", agentId: "agent-7", apiKey: "pk_test")

    private func client(_ answer: @escaping (URLRequest) -> (Int, Data)) throws -> DamClient {
        StubProtocol.answer = answer
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return try DamClient(account: account, session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubProtocol.answer = nil
        super.tearDown()
    }

    func testAPlainHttpHostIsRefusedBeforeTheKeyCanLeave() {
        XCTAssertThrowsError(try DamClient(account: DamAccount(host: "http://dam.example.com",
                                                               agentId: "agent-7", apiKey: "pk_test"))) {
            XCTAssertEqual($0 as? DamError, .insecureHost("http://dam.example.com"))
        }
        // A DAM on this machine is a development one; there is no network to listen on it.
        XCTAssertNoThrow(try DamClient(account: DamAccount(host: "http://localhost:3000",
                                                           agentId: "agent-7", apiKey: "pk_test")))
    }

    func testUploadGoesThroughTheProxyThatWakesTheAgent() async throws {
        var seen: URLRequest?
        var body: [String: Any] = [:]
        let c = try client { request in
            seen = request
            body = (try? JSONSerialization.jsonObject(with: request.bodyData ?? Data())) as? [String: Any] ?? [:]
            return (200, Data(#"{"result":{"data":{"mtimeMs":1}}}"#.utf8))
        }
        try await c.upload(path: "pen/s3-o27-b450-c1/p4.png", data: Data([0xDE, 0xAD]), contentType: "image/png")

        XCTAssertEqual(seen?.url?.absoluteString,
                       "https://dam.example.com/api/agents/agent-7/trpc/files.upload")
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "authorization"), "Bearer pk_test")
        XCTAssertEqual(body["path"] as? String, "pen/s3-o27-b450-c1/p4.png")
        XCTAssertEqual(body["contentBase64"] as? String, Data([0xDE, 0xAD]).base64EncodedString())
        // A page written on again must land on top of the one sent before it.
        XCTAssertEqual(body["overwrite"] as? Bool, true)
    }

    func testReadingBackTextCarriesTheModificationTime() async throws {
        let c = try client { _ in
            (200, Data(#"""
            {"result":{"data":{"path":"pen/p4.md","content":"# hello","binary":false,
             "mimeType":"text/markdown","mtimeMs":1757800000000}}}
            """#.utf8))
        }
        let file = try await c.read(path: "pen/p4.md")
        XCTAssertEqual(file.text, "# hello")
        XCTAssertEqual(file.mimeType, "text/markdown")
        XCTAssertEqual(file.mtimeMs, 1_757_800_000_000)
    }

    func testTheQueryCarriesTheInputAsOneEncodedValue() async throws {
        var seen: URL?
        let c = try client { request in
            seen = request.url
            return (200, Data(#"{"result":{"data":{"path":"a","content":"","binary":false,"mimeType":"text/plain","mtimeMs":0}}}"#.utf8))
        }
        _ = try await c.read(path: "pen/a b&c.md")
        // The whole JSON object is one query value; an unescaped `&` would cut it in half.
        XCTAssertEqual(seen?.absoluteString,
                       "https://dam.example.com/api/agents/agent-7/trpc/files.read?input=%7B%22path%22:%22pen/a%20b%26c.md%22%7D")
    }

    func testBinaryComesBackAsBytes() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let c = try client { _ in
            (200, Data("""
            {"result":{"data":{"path":"pen/p4.png","content":"\(png.base64EncodedString())","binary":true,
             "mimeType":"image/png","mtimeMs":2}}}
            """.utf8))
        }
        let file = try await c.read(path: "pen/p4.png")
        XCTAssertEqual(file.data, png)
    }

    func testAMissingFileIsNotAFault() async throws {
        let c = try client { _ in (404, Data(#"{"error":{"message":"NOT_FOUND","data":{"code":"NOT_FOUND"}}}"#.utf8)) }
        do {
            _ = try await c.read(path: "pen/p4.md")
            XCTFail("a missing file should be reported as missing")
        } catch {
            XCTAssertEqual(error as? DamError, .notFound(path: "pen/p4.md"))
        }
    }

    func testTheProxysOwnRefusalIsReadable() async throws {
        let c = try client { _ in
            (403, Data(#"{"error":"forbidden","message":"API key is not bound to agent agent-7"}"#.utf8))
        }
        do {
            try await c.upload(path: "pen/p4.png", data: Data(), contentType: "image/png")
            XCTFail("a forbidden upload should throw")
        } catch {
            XCTAssertEqual(error as? DamError,
                           .refused(procedure: "files.upload",
                                    detail: "forbidden: API key is not bound to agent agent-7"))
        }
    }

    func testAgentsAreListedOwnerWideNotThroughTheAgent() async throws {
        var seen: URL?
        let c = try client { request in
            seen = request.url
            return (200, Data(#"{"result":{"data":[{"id":"agent-7","name":"notes"},{"id":"agent-9"}]}}"#.utf8))
        }
        let agents = try await c.agents()
        XCTAssertEqual(seen?.absoluteString, "https://dam.example.com/api/trpc/agents.list")
        XCTAssertEqual(agents, [DamAgent(id: "agent-7", name: "notes"), DamAgent(id: "agent-9", name: "agent-9")])
    }
}

/// Answers every request in the session it is installed in, so no test reaches a network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var answer: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { answer != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.answer?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// `URLProtocol` hands the body back as a stream when it was set as data, so read either.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
