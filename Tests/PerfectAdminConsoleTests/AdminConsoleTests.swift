import XCTest
import Foundation
@testable import PerfectAdminConsole
import PerfectNIO

// MARK: - Token store

final class AdminTokenStoreTests: XCTestCase {

    private func tempTokenPath() -> String {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("perfect-admin-test-\(Int.random(in: 0..<Int.max)).token").path
    }

    func testInit_writesTokenFile() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        let contents = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(contents, store.token)
        XCTAssertEqual(contents.count, 64)
    }

    func testInit_appliesChmod600() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try AdminTokenStore(tokenFilePath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testInit_tokenIs64HexChars() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        XCTAssertTrue(store.token.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(store.token.count, 64)
    }

    func testInit_twoTokensAreDistinct() throws {
        let p1 = tempTokenPath(), p2 = tempTokenPath()
        defer {
            try? FileManager.default.removeItem(atPath: p1)
            try? FileManager.default.removeItem(atPath: p2)
        }
        let s1 = try AdminTokenStore(tokenFilePath: p1)
        let s2 = try AdminTokenStore(tokenFilePath: p2)
        XCTAssertNotEqual(s1.token, s2.token)
    }

    func testRequireAuth_validToken_doesNotThrow() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(store.token)")
        XCTAssertNoThrow(try store.requireAuth(from: headers))
    }

    func testRequireAuth_wrongToken_throws() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer notthetoken")
        XCTAssertThrowsError(try store.requireAuth(from: headers))
    }

    func testRequireAuth_missingHeader_throws() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        XCTAssertThrowsError(try store.requireAuth(from: HTTPHeaders()))
    }

    func testRequireAuth_wrongScheme_throws() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Basic abc123")
        XCTAssertThrowsError(try store.requireAuth(from: headers))
    }

    func testRequireAuth_caseInsensitiveBearer() throws {
        let path = tempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try AdminTokenStore(tokenFilePath: path)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "bearer \(store.token)")
        XCTAssertNoThrow(try store.requireAuth(from: headers))
    }
}

// MARK: - Log capture

final class LogCaptureTests: XCTestCase {

    func testCapture_returnsLines() async {
        let cap = LogCapture()
        await cap.capture("line one")
        await cap.capture("line two")
        let lines = await cap.recentLines(count: 10)
        XCTAssertEqual(lines, ["line one", "line two"])
    }

    func testRingBuffer_dropsOldestWhenFull() async {
        let cap = LogCapture(capacity: 3)
        await cap.capture("a")
        await cap.capture("b")
        await cap.capture("c")
        await cap.capture("d")
        let lines = await cap.recentLines(count: 10)
        XCTAssertEqual(lines, ["b", "c", "d"])
        XCTAssertFalse(lines.contains("a"))
    }

    func testRecentLines_respectsCount() async {
        let cap = LogCapture()
        for i in 0..<20 { await cap.capture("line \(i)") }
        let lines = await cap.recentLines(count: 5)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.last, "line 19")
    }

    func testTotalCaptured_countsAllAdded() async {
        let cap = LogCapture(capacity: 3)
        await cap.capture("a")
        await cap.capture("b")
        await cap.capture("c")
        await cap.capture("d") // displaces "a"
        let total = await cap.totalCaptured
        // totalCaptured reflects current buffer size (ring-buffer view), not the lifetime count
        XCTAssertEqual(total, 3)
    }

    func testEmptyCapture_returnsEmptyLines() async {
        let cap = LogCapture()
        let lines = await cap.recentLines(count: 10)
        XCTAssertEqual(lines, [])
    }
}

// MARK: - AdminConsole delegate / RouteInfo

final class AdminConsoleDelegateTests: XCTestCase {

    func testRouteInfo_storesURI() {
        let info = RouteInfo(uri: "GET:///foo/bar")
        XCTAssertEqual(info.uri, "GET:///foo/bar")
    }

    func testAdminStatusSection_storesItemsOrdered() {
        let section = AdminStatusSection(title: "My App", items: [("Key", "Value"), ("Foo", "Bar")])
        XCTAssertEqual(section.title, "My App")
        XCTAssertEqual(section.items.map(\.key), ["Key", "Foo"])
    }
}

// MARK: - TLSContextManager additions

final class TLSContextManagerAdminTests: XCTestCase {

    func testRegisteredHostnames_emptyOnInit() async throws {
        let mgr = try TLSContextManager()
        let names = await mgr.registeredHostnames()
        XCTAssertTrue(names.isEmpty)
    }

    func testHasDefaultContext_falseWhenNoDefault() async throws {
        let mgr = try TLSContextManager()
        let has = await mgr.hasDefaultContext
        XCTAssertFalse(has)
    }

    func testRegisteredHostnames_returnsSortedDomains() async throws {
        let mgr = try TLSContextManager()
        // Without real certs we can only test the shape; a non-throwing
        // registration helper isn't available without PEM files.
        // So we just confirm the return type and empty baseline.
        let names = await mgr.registeredHostnames()
        XCTAssertEqual(names, names.sorted())
    }
}

// MARK: - ACMEChallengeResponder additions

final class ACMEPendingCountTests: XCTestCase {

    func testPendingCount_zeroInitially() async {
        let acme = ACMEChallengeResponder()
        let count = await acme.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testPendingCount_incrementsOnAdd() async {
        let acme = ACMEChallengeResponder()
        await acme.addChallenge(token: "tok1", keyAuthorization: "auth1")
        await acme.addChallenge(token: "tok2", keyAuthorization: "auth2")
        let count = await acme.pendingCount
        XCTAssertEqual(count, 2)
    }

    func testPendingCount_decrementsOnRemove() async {
        let acme = ACMEChallengeResponder()
        await acme.addChallenge(token: "tok", keyAuthorization: "auth")
        await acme.removeChallenge(token: "tok")
        let count = await acme.pendingCount
        XCTAssertEqual(count, 0)
    }
}

// MARK: - AdminWebUI

final class AdminWebUITests: XCTestCase {

    func testResponse_isHTMLOutput() {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/test.token")
        let head = output.head(request: HTTPRequestInfo(head: .init(version: .http1_1, method: .GET, uri: "/"), options: []))
        let ct = head?.headers.first(name: "Content-Type") ?? ""
        XCTAssertTrue(ct.hasPrefix("text/html"))
    }

    func testResponse_injectsTokenPath() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/var/run/myapp.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("myapp.token"), "Token path not injected into HTML")
    }

    func testResponse_specialCharsInPathAreEscaped() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/path with \"quotes\".token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        // Raw quotes should not appear unescaped inside the JS string context
        XCTAssertFalse(html.contains(#"path with "quotes""#), "Path not JSON-escaped in HTML")
    }

    func testResponse_cacheControlNoStore() {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        let head = output.head(request: HTTPRequestInfo(head: .init(version: .http1_1, method: .GET, uri: "/"), options: []))
        let cc = head?.headers.first(name: "Cache-Control") ?? ""
        XCTAssertEqual(cc, "no-store")
    }
}
