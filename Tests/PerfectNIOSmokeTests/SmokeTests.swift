//
//  SmokeTests.swift
//  PerfectNIOSmokeTests
//
//  Validates Phase 2 (async route chain) and Phase 3 (HTTPOutput.nextChunk) end-to-end.
//  Uses URLSession — no external dependencies beyond Foundation.
//
//  Port 42100 (old tests use 42000). Tests in a single XCTestCase class run serially,
//  so port reuse between tests is safe as long as each test defers server.stop().
//

import XCTest
import Foundation
import NIO
import NIOHTTP1
@testable import PerfectNIO

final class PerfectNIOSmokeTests: XCTestCase {

    private let port = 42100
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func url(_ path: String) -> URL {
        URL(string: "http://localhost:\(port)\(path)")!
    }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(from: url(path))
        return (data, response as! HTTPURLResponse)
    }

    private func post(
        _ path: String,
        body: Data,
        contentType: String = "application/octet-stream"
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        return (data, response as! HTTPURLResponse)
    }

    // MARK: - Pure unit test (no server needed)

    func testQueryDecoder() {
        // sentinel=x ensures empty= is not the last token — QueryDecoder stores the name
        // including the "=" when the key=value pair is at the very end of the string.
        let q = QueryDecoder(Array("a=1&b=2&b=3&novalue&empty=&sentinel=x".utf8))
        XCTAssertEqual(q["a"], ["1"])
        XCTAssertEqual(q["b"], ["2", "3"])
        // Key with no "=" followed by "&" → one empty-string value
        XCTAssertEqual(q["novalue"], [""])
        // Key with "=" and empty value (not at end of string) → one empty-string value
        XCTAssertEqual(q["empty"], [""])
        XCTAssertEqual(q["sentinel"], ["x"])
        XCTAssertEqual(q["missing"], [])
    }

    // MARK: - Basic routing

    func testBasicText() async throws {
        let server = try root { "OK" }.text().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, response) = try await get("/")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "OK")
    }

    func testMultiplePaths() async throws {
        let p = root(path: "/", HTTPRequest.self)
        let server = try root().dir(
            p.alpha { "alpha" },
            p.beta  { "beta"  }
        ).text().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (d1, r1) = try await get("/alpha")
        XCTAssertEqual(r1.statusCode, 200)
        XCTAssertEqual(String(data: d1, encoding: .utf8), "alpha")

        let (d2, r2) = try await get("/beta")
        XCTAssertEqual(r2.statusCode, 200)
        XCTAssertEqual(String(data: d2, encoding: .utf8), "beta")
    }

    func testNotFound() async throws {
        let server = try root { "OK" }.text().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (_, response) = try await get("/does-not-exist")
        XCTAssertEqual(response.statusCode, 404)
    }

    func testDuplicateRouteThrows() {
        let p = root(path: "/", HTTPRequest.self)
        XCTAssertThrowsError(
            try root().dir(p.foo { "first" }, p.foo { "second" }).text()
        ) { error in
            if case RouteError.duplicatedRoutes = error { } else {
                XCTFail("Expected RouteError.duplicatedRoutes, got \(error)")
            }
        }
    }

    // MARK: - URI matching

    func testWildcard() async throws {
        // /captured/suffix — wild captures the first segment, "suffix" is a literal path step
        let server = try root().wild { $1 }.suffix.text().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, response) = try await get("/hello/suffix")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testNamedWildcard() async throws {
        let server = try root()
            .wild(name: "id")
            .info
            .request { (_, req) in req.uriVariables["id"] ?? "missing" }
            .text()
            .bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, response) = try await get("/abc123/info")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "abc123")
    }

    func testTrailingWildcard() async throws {
        let server = try root().base.trailing { $1 }.text().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, _) = try await get("/base/a/b/c")
        XCTAssertEqual(String(data: data, encoding: .utf8), "a/b/c")
    }

    // MARK: - HTTP method routing

    func testMethodRouting() async throws {
        let p = root(path: "/", HTTPRequest.self)
        let server = try root().dir(
            p.GET.getonly  { "GET response"  },
            p.POST.postonly { "POST response" }
        ).text().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (d1, r1) = try await get("/getonly")
        XCTAssertEqual(r1.statusCode, 200)
        XCTAssertEqual(String(data: d1, encoding: .utf8), "GET response")

        let (d2, r2) = try await post("/postonly", body: Data())
        XCTAssertEqual(r2.statusCode, 200)
        XCTAssertEqual(String(data: d2, encoding: .utf8), "POST response")

        // Wrong method → 404
        let (_, r3) = try await post("/getonly", body: Data())
        XCTAssertEqual(r3.statusCode, 404)
    }

    // MARK: - Response types

    func testJSONOutput() async throws {
        struct Greeting: Codable { let message: String }
        let server = try root { Greeting(message: "hello") }.json().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, response) = try await get("/")
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try JSONDecoder().decode(Greeting.self, from: data)
        XCTAssertEqual(decoded.message, "hello")
    }

    func testStatusCheck() async throws {
        let p = root(path: "/", HTTPRequest.self)
        let server = try root().dir(
            p.ok.statusCheck { .ok }.map { "OK" },
            p.forbidden.statusCheck { HTTPResponseStatus.forbidden }.map { "NEVER" }
        ).text().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, r1) = try await get("/ok")
        XCTAssertEqual(r1.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "OK")

        let (_, r2) = try await get("/forbidden")
        XCTAssertEqual(r2.statusCode, 403)
    }

    func testUnwrap() async throws {
        let p = root(path: "/", HTTPRequest.self)
        let routes: Routes<HTTPRequest, String?> = try root().dir(
            p.present { Optional("found") },
            p.absent  { Optional<String>.none }
        )
        let server = try routes.unwrap { $0 }.text().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, r1) = try await get("/present")
        XCTAssertEqual(r1.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "found")

        let (_, r2) = try await get("/absent")
        XCTAssertEqual(r2.statusCode, 500)
    }

    // MARK: - Request body handling

    func testPOSTBodyReading() async throws {
        let server = try root().POST.readBody { (_, body) -> String in
            switch body {
            case .other(let bytes): return String(bytes: bytes, encoding: .utf8) ?? "?"
            default: return "unexpected content type"
            }
        }.text().bind(port: port).listen()
        defer { try? server.stop().wait() }

        let payload = "hello from the test"
        let (data, response) = try await post("/", body: Data(payload.utf8))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), payload)
    }

    func testJSONDecode() async throws {
        struct Payload: Codable { let x: Int }
        let server = try root().POST
            .decode(Payload.self) { payload in payload.x * 2 }
            .json()
            .bind(port: port).listen()
        defer { try? server.stop().wait() }

        let body = try JSONEncoder().encode(Payload(x: 21))
        let (data, response) = try await post("/", body: body, contentType: "application/json")
        XCTAssertEqual(response.statusCode, 200)
        let result = try JSONDecoder().decode(Int.self, from: data)
        XCTAssertEqual(result, 42)
    }

    // MARK: - Phase 3: custom HTTPOutput.nextChunk()

    func testCustomNextChunkOutput() async throws {
        // Verifies that the async nextChunk() pull loop in NIOHTTPHandler works end-to-end.
        class ChunkedOutput: HTTPOutput, @unchecked Sendable {
            var count = 0
            override func head(request: HTTPRequestInfo) -> HTTPHead? {
                HTTPHead(headers: HTTPHeaders([("Content-Length", "4096")]))
            }
            override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
                guard count < 4 else { return nil }
                let byte = UInt8(48 + count) // '0', '1', '2', '3'
                count += 1
                var buf = allocator.buffer(capacity: 1024)
                buf.writeRepeatingByte(byte, count: 1024)
                return buf
            }
        }

        let server = try root { ChunkedOutput() as HTTPOutput }.bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, response) = try await get("/")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data.count, 4096)
        XCTAssertEqual(data[0],    UInt8(ascii: "0"))
        XCTAssertEqual(data[1023], UInt8(ascii: "0"))
        XCTAssertEqual(data[1024], UInt8(ascii: "1"))
        XCTAssertEqual(data[2048], UInt8(ascii: "2"))
        XCTAssertEqual(data[3072], UInt8(ascii: "3"))
    }

    // MARK: - Built-in output types

    func testFileOutput() async throws {
        let tmpPath = "/tmp/smoke-\(UUID().uuidString).txt"
        let content = "file content from PerfectNIO"
        try Data(content.utf8).write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let server = try root().f { try FileOutput(localPath: tmpPath) as HTTPOutput }
            .bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, response) = try await get("/f")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), content)
    }

    func testCompression() async throws {
        // 16 KB — above CompressedOutput.minCompressLength (~14 KB), so gzip is applied.
        // URLSession transparently decompresses gzip; we verify the round-tripped content.
        // A broken compressor produces wrong or missing content, causing the assertion to fail.
        let bytes: [UInt8] = (0..<16).flatMap { i in
            Array(String(repeating: "\(i % 10)", count: 1024).utf8)
        }
        let expected = String(bytes: bytes, encoding: .utf8)!

        let server = try root { BytesOutput(body: bytes) as HTTPOutput }
            .compressed()
            .bind(port: port).listen()
        defer { try? server.stop().wait() }

        let (data, response) = try await get("/")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), expected)
    }
}
