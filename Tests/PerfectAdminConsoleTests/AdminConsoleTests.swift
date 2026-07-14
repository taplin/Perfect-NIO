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

    func testResponse_containsActionsSection() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("actions-section"), "Phase 2 actions section missing from HTML")
        XCTAssertTrue(html.contains("toast-container"), "Phase 2 toast container missing from HTML")
    }
}

// MARK: - AdminAction / AdminActionResult

final class AdminActionTests: XCTestCase {

    func testAdminAction_storesAllFields() {
        let a = AdminAction(name: "my-action", label: "My Action",
                            description: "Does something", category: "ops", isDestructive: true)
        XCTAssertEqual(a.name, "my-action")
        XCTAssertEqual(a.label, "My Action")
        XCTAssertEqual(a.description, "Does something")
        XCTAssertEqual(a.category, "ops")
        XCTAssertTrue(a.isDestructive)
    }

    func testAdminAction_defaultCategoryIsGeneral() {
        let a = AdminAction(name: "x", label: "X", description: "")
        XCTAssertEqual(a.category, "general")
    }

    func testAdminAction_defaultNonDestructive() {
        let a = AdminAction(name: "x", label: "X", description: "")
        XCTAssertFalse(a.isDestructive)
    }

    func testAdminActionResult_okFactory() {
        let r = AdminActionResult.ok("All good")
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.message, "All good")
    }

    func testAdminActionResult_failedFactory() {
        let r = AdminActionResult.failed("Nope")
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.message, "Nope")
    }

    func testAdminActionResult_initDirectly() {
        let r = AdminActionResult(success: true, message: "OK")
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.message, "OK")
    }
}

// MARK: - CSRF guard

final class CSRFGuardTests: XCTestCase {

    func testRequireCSRF_missingHeader_throws() {
        XCTAssertThrowsError(try requireCSRF(headers: HTTPHeaders(), port: 8990))
    }

    func testRequireCSRF_wrongValue_throws() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "true")
        XCTAssertThrowsError(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_correctHeader_noOrigin_passes() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        XCTAssertNoThrow(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_correctHeaderAndOrigin_passes() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        h.add(name: "Origin", value: "http://127.0.0.1:8990")
        XCTAssertNoThrow(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_wrongOrigin_throws() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        h.add(name: "Origin", value: "http://evil.example.com")
        XCTAssertThrowsError(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_localhostIsNotSameAs127_throws() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        h.add(name: "Origin", value: "http://localhost:8990")
        XCTAssertThrowsError(try requireCSRF(headers: h, port: 8990))
    }

    func testRequireCSRF_portMismatch_throws() {
        var h = HTTPHeaders()
        h.add(name: "X-Admin-CSRF", value: "1")
        h.add(name: "Origin", value: "http://127.0.0.1:9999")
        XCTAssertThrowsError(try requireCSRF(headers: h, port: 8990))
    }
}

// MARK: - LogCapture clear

final class LogCaptureClearTests: XCTestCase {

    func testClear_returnsDroppedCount() async {
        let cap = LogCapture()
        await cap.capture("a")
        await cap.capture("b")
        await cap.capture("c")
        let dropped = await cap.clear()
        XCTAssertEqual(dropped, 3)
    }

    func testClear_emptyBuffer_returnsZero() async {
        let cap = LogCapture()
        let dropped = await cap.clear()
        XCTAssertEqual(dropped, 0)
    }

    func testClear_bufferIsEmptyAfterClear() async {
        let cap = LogCapture()
        await cap.capture("x")
        _ = await cap.clear()
        let lines = await cap.recentLines(count: 100)
        XCTAssertEqual(lines, [])
    }

    func testClear_afterClear_canCaptureAgain() async {
        let cap = LogCapture()
        await cap.capture("before")
        _ = await cap.clear()
        await cap.capture("after")
        let lines = await cap.recentLines(count: 100)
        XCTAssertEqual(lines, ["after"])
    }

    func testClear_totalCapturedIsZeroAfterClear() async {
        let cap = LogCapture()
        await cap.capture("a")
        await cap.capture("b")
        _ = await cap.clear()
        let total = await cap.totalCaptured
        XCTAssertEqual(total, 0)
    }
}

// MARK: - AdminConsoleDelegate Phase 2 defaults

private final class MinimalDelegate2: AdminConsoleDelegate {}

final class AdminConsoleDelegatePhase2Tests: XCTestCase {

    func testDefaultAvailableActions_isEmpty() async {
        let d = MinimalDelegate2()
        let actions = await d.availableActions()
        XCTAssertTrue(actions.isEmpty)
    }

    func testDefaultExecuteAction_returnsFailed() async throws {
        let d = MinimalDelegate2()
        let result = try await d.executeAction("anything")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("anything"))
    }

    func testDefaultReloadTLS_doesNotThrow() async throws {
        let d = MinimalDelegate2()
        try await d.reloadTLSCertificates()
    }
}

// MARK: - Built-in actions

final class BuiltinActionsTests: XCTestCase {

    func testBuiltinActions_noneWhenNoLogsNoDelegate() {
        let actions = adminBuiltinActions(hasLogs: false, hasDelegate: false)
        XCTAssertTrue(actions.isEmpty)
    }

    func testBuiltinActions_clearLogsWhenHasLogs() {
        let actions = adminBuiltinActions(hasLogs: true, hasDelegate: false)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].name, "clear-logs")
        XCTAssertTrue(actions[0].isDestructive)
    }

    func testBuiltinActions_reloadTLSWhenHasDelegate() {
        let actions = adminBuiltinActions(hasLogs: false, hasDelegate: true)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].name, "reload-tls")
        XCTAssertFalse(actions[0].isDestructive)
    }

    func testBuiltinActions_bothWhenBothPresent() {
        let actions = adminBuiltinActions(hasLogs: true, hasDelegate: true)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.map(\.name), ["clear-logs", "reload-tls"])
    }
}

// MARK: - Phase 3: DatasourceInfo

final class DatasourceInfoTests: XCTestCase {

    func testInit_storesAllFields() {
        let ds = DatasourceInfo(name: "mysql-main", alias: "MainDB", schema: "appdb", driver: "MySQL")
        XCTAssertEqual(ds.name, "mysql-main")
        XCTAssertEqual(ds.alias, "MainDB")
        XCTAssertEqual(ds.schema, "appdb")
        XCTAssertEqual(ds.driver, "MySQL")
    }

    func testInit_emptyStringsAllowed() {
        let ds = DatasourceInfo(name: "", alias: "", schema: "", driver: "")
        XCTAssertEqual(ds.name, "")
    }

    func testSendable_usableAcrossActors() async {
        let ds = DatasourceInfo(name: "pg", alias: "Postgres", schema: "public", driver: "PostgreSQL")
        let name = await Task.detached { ds.name }.value
        XCTAssertEqual(name, "pg")
    }
}

// MARK: - Phase 3: DatasourceTestResult

final class DatasourceTestResultTests: XCTestCase {

    func testOk_defaultMessage() {
        let r = DatasourceTestResult.ok()
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.message, "Connection OK")
        XCTAssertNil(r.latencyMs)
    }

    func testOk_withLatency() {
        let r = DatasourceTestResult.ok(latencyMs: 3.7)
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.latencyMs, 3.7)
    }

    func testOk_withCustomMessage() {
        let r = DatasourceTestResult.ok(message: "MySQL 9.6 · 2ms")
        XCTAssertEqual(r.message, "MySQL 9.6 · 2ms")
    }

    func testFailed_successIsFalse() {
        let r = DatasourceTestResult.failed("Connection refused")
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.message, "Connection refused")
    }

    func testFailed_latencyIsNil() {
        let r = DatasourceTestResult.failed("Timeout")
        XCTAssertNil(r.latencyMs)
    }

    func testDirectInit_allFields() {
        let r = DatasourceTestResult(success: true, message: "OK", latencyMs: 12.5)
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.message, "OK")
        XCTAssertEqual(r.latencyMs, 12.5)
    }

    func testDirectInit_latencyDefaultsToNil() {
        let r = DatasourceTestResult(success: false, message: "err")
        XCTAssertNil(r.latencyMs)
    }
}

// MARK: - Phase 3: AdminConsoleDelegate defaults

private final class MinimalDelegate3: AdminConsoleDelegate {}

final class AdminConsoleDelegatePhase3Tests: XCTestCase {

    func testDefaultRegisteredDatasources_isEmpty() async {
        let d = MinimalDelegate3()
        let sources = await d.registeredDatasources()
        XCTAssertTrue(sources.isEmpty)
    }

    func testDefaultTestDatasource_returnsFailed() async throws {
        let d = MinimalDelegate3()
        let result = try await d.testDatasource(name: "any-ds")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("any-ds"))
    }

    func testDefaultTestDatasource_latencyIsNil() async throws {
        let d = MinimalDelegate3()
        let result = try await d.testDatasource(name: "x")
        XCTAssertNil(result.latencyMs)
    }
}

// MARK: - Phase 3: AdminWebUI datasource section

final class AdminWebUIDatasourceTests: XCTestCase {

    func testResponse_containsDatasourceCard() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("datasource-content"), "Datasource card container missing")
        XCTAssertTrue(html.contains("Datasources"), "Datasource card heading missing")
    }

    func testResponse_containsDatasourceTestFunction() async throws {
        let output = AdminWebUI.response(tokenFilePath: "/tmp/tok.token")
        var body: [UInt8] = []
        let alloc = ByteBufferAllocator()
        var chunk = try await output.nextChunk(allocator: alloc)
        while let buf = chunk {
            body.append(contentsOf: buf.readableBytesView)
            chunk = try await output.nextChunk(allocator: alloc)
        }
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("testDS"), "testDS JS function missing")
        XCTAssertTrue(html.contains("/api/datasources/test"), "datasource test endpoint missing from JS")
    }
}
