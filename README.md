<p align="center">
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Swift-6.0-orange.svg?style=flat" alt="Swift 6.0">
    </a>
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Platforms-macOS%20%7C%20Linux-lightgray.svg?style=flat" alt="Platforms macOS | Linux">
    </a>
    <a href="http://perfect.org/licensing.html" target="_blank">
        <img src="https://img.shields.io/badge/License-Apache-lightgrey.svg?style=flat" alt="License Apache">
    </a>
</p>

# PerfectNIO

A Swift 6 HTTP(S) server library built on SwiftNIO. Routes are a composable, strongly-typed pipeline: each step accepts one type and produces another, terminating in an `HTTPOutput` that writes the response. The library is an updated resurrection of the original [Perfect-NIO](https://github.com/PerfectlySoft/Perfect-NIO) project.

- [Quick start](#quick-start)
- [Package.swift](#packageswift)
- [Routing](#routing)
- [Route operations](#route-operations)
- [HTTP methods](#http-methods)
- [Output types](#output-types)
- [Custom HTTPOutput](#custom-httpoutput)
- [WebSocket](#websocket)
- [TLS / HTTPS](#tls--https)
- [Admin console](#admin-console)
- [Reference](#reference)
- [Linux support](#linux-support)

---

## Quick start

```swift
// Sources/MyServer/main.swift
import PerfectNIO

let routes = root { "Hello, world!" }.text()
try await Server(routes: routes, port: 8080).run()
```

Build and run with `swift run`. The server listens on port 8080 and responds to every request with `Hello, world!`.

### Scoped server (useful in tests)

```swift
try await Server(routes: routes, port: 8080).withServer { boundPort in
    // server is live; boundPort is the actually-bound port (useful when port: 0)
}
// server has shut down
```

---

## Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/taplin/Perfect-NIO.git", branch: "swiftCoreUpdate"),
],
targets: [
    .target(
        name: "MyServer",
        dependencies: [
            .product(name: "PerfectNIO", package: "Perfect-NIO"),
        ]
    ),
]
```

Your code will typically `import PerfectNIO`. The library re-exports `NIO`, `NIOHTTP1`, and `NIOSSL`, so you usually do not need to import those separately.

Optional: add `PerfectNIOMustache` for Mustache template output.

---

## Routing

### root()

Every route tree starts with `root()`. It creates a single route at `/` that passes the `HTTPRequest` through unchanged.

```swift
root()                          // Routes<HTTPRequest, HTTPRequest>
root { "Hello" }               // Routes<HTTPRequest, String> — ignores the request
root { req in req.path }       // Routes<HTTPRequest, String> — uses the request
```

### Path components

Append path segments using Swift dynamic member lookup or the `path` function:

```swift
root().hello.world { "Hello, world!" }.text()   // serves /hello/world
root().path("hello").path("world") { "Hello" }.text()
root().path("hello/world") { "Hello" }.text()   // equivalent
```

Numeric path components are valid via dynamic member lookup even though Swift does not normally allow them as identifiers:

```swift
root().v1.path("2024").reports { loadReports() }.json()
```

### Combining routes

Use `dir` to compose multiple routes into one. `dir` throws `RouteError.duplicatedRoutes` if any two routes resolve to the same URI.

```swift
let routes = try root().dir(
    root().hello { "Hello" },
    root().bye   { "Bye"   }
).text()

try await Server(routes: routes, port: 8080).run()
// serves /hello and /bye
```

Closure form — the argument `$0` is a stand-in for the parent route:

```swift
let routes = try root().v1.dir {[
    $0.foo1 { "OK1" },
    $0.foo2 { "OK2" },
    $0.foo3 { "OK3" },
]}.text()
// serves /v1/foo1, /v1/foo2, /v1/foo3
```

Because routes are strongly typed, all routes passed to `dir` must share the same `OutType`. Mismatches are caught at compile time.

---

## Route operations

All route closures are `async throws`. Return a value to pass it to the next operation, or throw to abort the request.

### map

Transform the current output value into something new.

```swift
// Routes<HTTPRequest, [String]>
let routes = try root().dir {[
    $0.a { 1 }.map { "\($0)" },            // Int → String
    $0.b { [1, 2, 3] }.map { "\($0)" },    // each Int → String
]}.text()
```

### ext

Match a file extension in the URI. Useful for serving the same data in multiple formats.

```swift
struct Report: Codable, CustomStringConvertible {
    let id: Int
    var description: String { "Report \(id)" }
}
let base = root().reports { Report(id: 1) }
let routes = try root().dir(
    base.ext("json").json(),   // /reports.json
    base.ext("txt").text()     // /reports.txt
)
```

### wild

Match a single path segment as a wildcard.

```swift
// /*/suffix — captures the first segment
root().wild { $1 }.suffix.text()

// Named wildcard — value stored in req.uriVariables
root().v1.wild(name: "id").info
    .request { _, req in req.uriVariables["id"] ?? "" }
    .text()
```

### trailing

Match all remaining path segments.

```swift
// /files/** — captures everything after /files/
root().files.trailing { $1 }.text()
// /files/docs/2024/report.txt → "docs/2024/report.txt"
```

### request

Re-expose the `HTTPRequest` to a handler that has already moved to a different value.

```swift
root().hello { "Hello" }.request { greeting, req in
    "\(greeting) from \(req.path)"
}.text()
```

### readBody

Read the request body and branch on content type.

```swift
root().upload.POST.readBody { _, content in
    switch content {
    case .multiPartForm(let form): return "multipart: \(form.bodySpecs.count) parts"
    case .urlForm(let q):          return "form: \(q["name"].first ?? "")"
    case .other(let bytes):        return "raw: \(bytes.count) bytes"
    case .none:                    return "empty"
    }
}.text()
```

### decode

Read and decode the request body as a `Decodable` type.

```swift
struct CreateUser: Decodable { let name: String; let email: String }

// Decoded value replaces the pipeline value
root().POST.users.decode(CreateUser.self) { user in
    "\(user.name) created"
}.text()

// Both the previous value and the decoded value are available
root().POST.users
    .decode(CreateUser.self) { prev, user in user }
    .json()
```

### statusCheck

Inspect the current value and return an HTTP status. Any non-2xx status aborts the request.

```swift
root().admin
    .statusCheck { req in req.headers["X-Admin-Key"].first == "secret" ? .ok : .forbidden }
    .map { "Welcome, admin" }
    .text()
```

### unwrap

Safely unwrap an `Optional` output. Aborts with 500 if the value is `nil`.

```swift
let routes = try root().dir(
    root().found  { Optional("value") },
    root().missing { Optional<String>.none }
).unwrap { $0 }.text()
// /found → "value", /missing → 500
```

### Auth pattern — statusCheck + unwrap

The canonical auth gate pattern:

```swift
struct Session: Sendable {
    let userId: String
}

func session(from req: any HTTPRequest) -> Session? {
    guard let token = req.headers["Authorization"].first else { return nil }
    return validateToken(token).map { Session(userId: $0) }
}

let protected = root(session(from:))
    .statusCheck { $0 == nil ? .unauthorized : .ok }
    .unwrap { $0 }

// All routes chained from `protected` have access to a non-nil Session
let routes = protected.request { session, _ in session.userId }.text()
```

---

## HTTP methods

Without a method constraint, a route answers any HTTP method. Constrain with a property:

```swift
let routes = try root().dir {[
    $0.GET.users   { listUsers()   }.json(),
    $0.POST.users  { createUser()  }.json(),
    $0.DELETE.users { deleteUsers() }.text(),
]}.text()
```

Accept multiple methods with `method(_:)`:

```swift
root().method(.GET, .HEAD).ping { "pong" }.text()
```

---

## Output types

### text()

Returns the value's `description` with `Content-Type: text/plain`.

```swift
root { 42 }.text()                       // "42"
root { Date() }.text()                    // ISO date string
root().hello { "Hello, world!" }.text()
```

### json()

Encodes an `Encodable` value as JSON with `Content-Type: application/json`.

```swift
struct User: Codable { let id: Int; let name: String }
root().user { User(id: 1, name: "Alice") }.json()
```

### compressed()

Wraps any `HTTPOutput` with gzip/deflate compression. Content shorter than ~14 KB or with an image/video/audio content type is passed through uncompressed.

```swift
root { BytesOutput(body: largeBytes) as HTTPOutput }.compressed()
```

### FileOutput

Serves a local file.

```swift
root().logo {
    try FileOutput(localPath: "/var/www/logo.png") as HTTPOutput
}.ext("png")
```

### MustacheOutput

Renders a Mustache template (requires the `PerfectNIOMustache` target).

```swift
import PerfectNIOMustache

root().page {
    try MustacheOutput(
        templatePath: "/var/www/template.html",
        inputs: ["title": "Home", "items": items],
        contentType: "text/html"
    ) as HTTPOutput
}.ext("html")
```

---

## Custom HTTPOutput

Subclass `HTTPOutput` to produce body data in chunks. Return `nil` from `nextChunk` to signal end of body.

```swift
class StreamOutput: HTTPOutput, @unchecked Sendable {
    var page = 0

    override func head(request: HTTPRequestInfo) -> HTTPHead? {
        HTTPHead(headers: HTTPHeaders([("Content-Type", "text/plain")]))
    }

    override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
        guard page < 16 else { return nil }
        let chunk = String(repeating: "\(page % 10)", count: 1024)
        page += 1
        var buf = allocator.buffer(capacity: chunk.utf8.count)
        buf.writeString(chunk)
        return buf
    }
}

// Combine with .compressed() for streaming compression
let route = root { StreamOutput() as HTTPOutput }.compressed()
```

`closed()` is called once the response is fully written (or on error). Override it to release resources.

```swift
class FileStreamOutput: HTTPOutput, @unchecked Sendable {
    let handle: FileHandle
    init(path: String) throws {
        guard let h = FileHandle(forReadingAtPath: path) else {
            throw ErrorOutput(status: .notFound)
        }
        handle = h
    }
    override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
        let data = handle.readData(ofLength: 65536)
        guard !data.isEmpty else { return nil }
        var buf = allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        return buf
    }
    override func closed() { handle.closeFile() }
}
```

---

## WebSocket

Declare a WebSocket endpoint with `webSocket(protocol:options:_:)`. The callback runs through the normal route pipeline and returns a `WebSocketHandler` — a closure that drives the live connection.

```swift
let echoRoute = root().echo.webSocket(protocol: "echo") { _ -> WebSocketHandler in
    return { ws in
        while true {
            do {
                switch try await ws.readMessage() {
                case .text(let s):   try await ws.writeMessage(.text(s))
                case .binary(let b): try await ws.writeMessage(.binary(b))
                case .close:         try await ws.writeMessage(.close); return
                default:             break
                }
            } catch { return }
        }
    }
}
```

A WebSocket handshake to a path that does not have a `webSocket()` route is served as ordinary HTTP (returning the route's natural status, typically 404) — per RFC 6455 §4.2.2.

### WebSocketOption

| Option | Effect |
|---|---|
| `.manualClose` | Handler must reply to `.close` frames itself; otherwise auto-close-echo is sent |
| `.manualPing` | Handler must reply to `.ping` frames; otherwise auto-pong is sent |

---

## TLS / HTTPS

Pass a `TLSConfiguration` to `Server`. The private key and certificate can be loaded from PEM files or from embedded bytes.

```swift
import NIOSSL

let cert = try NIOSSLCertificate(file: "/etc/ssl/cert.pem", format: .pem)
let key  = try NIOSSLPrivateKey(file: "/etc/ssl/key.pem",  format: .pem)
let tls  = TLSConfiguration.makeServerConfiguration(
    certificateChain: [.certificate(cert)],
    privateKey: .privateKey(key)
)

try await Server(routes: routes, port: 443, tls: tls).run()
```

---

## Admin console

`PerfectAdminConsole` is an optional SPM library target that starts a lightweight read/write admin server bound exclusively to `127.0.0.1`. It is never included unless the host application explicitly depends on it.

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/taplin/Perfect-NIO.git", branch: "main"),
],
targets: [
    .target(
        name: "MyServer",
        dependencies: [
            .product(name: "PerfectNIO", package: "Perfect-NIO"),
            .product(name: "PerfectAdminConsole", package: "Perfect-NIO"),
        ]
    ),
]
```

### Basic setup

```swift
import PerfectAdminConsole

let logCapture = LogCapture()          // optional — omit if you don't need log tail
let admin = try AdminConsole(
    port: 8990,
    tokenFilePath: "/var/run/myapp-admin.token",
    tlsManager: certManager,           // optional — from PerfectNIO TLS setup
    acmeResponder: acme,               // optional
    logCapture: logCapture,
    delegate: myServer                 // optional — see AdminConsoleDelegate below
)
async let _ = admin.run()             // binds 127.0.0.1:8990, prints token path to stderr
```

The token file is created at startup with `chmod 600`. Read it once to authenticate:

```bash
TOKEN=$(cat /var/run/myapp-admin.token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8990/api/status | jq
```

### Phase 1 — read-only API

All endpoints require `Authorization: Bearer <token>`.

| Endpoint | Response |
|---|---|
| `GET /` | HTML dashboard (no auth — loads the token-entry form) |
| `GET /api/status` | Server uptime, TLS domain count, ACME pending challenges, delegate sections |
| `GET /api/tls` | `{domains: [String], hasDefault: Bool}` |
| `GET /api/acme` | `{pendingChallenges: Int}` |
| `GET /api/logs?count=N` | `{lines: [String], totalCaptured: Int}` — last N lines from `LogCapture` |
| `GET /api/routes` | `{routes: [String]}` — from delegate |
| `GET /api/actions` | `{actions: [...]}` — available actions (built-in + delegate) |

### Phase 2 — mutating API

Mutating endpoints additionally require `X-Admin-CSRF: 1`. When an `Origin` header is present it must equal `http://127.0.0.1:<port>`.

| Endpoint | Body | Effect |
|---|---|---|
| `POST /api/actions` | `{"action": "clear-logs"}` | Execute an action by name |
| `POST /api/actions` | `{"action": "reload-tls"}` | Ask delegate to reload TLS certs |
| `DELETE /api/logs` | — | Clear the log ring buffer immediately |

```bash
TOKEN=$(cat /var/run/myapp-admin.token)

# Clear logs
curl -s -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Admin-CSRF: 1" \
  http://127.0.0.1:8990/api/logs | jq

# Execute an action
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Admin-CSRF: 1" \
  -H "Content-Type: application/json" \
  -d '{"action":"reload-tls"}' \
  http://127.0.0.1:8990/api/actions | jq
```

### AdminConsoleDelegate

Implement this protocol (all methods are optional via default implementations) to expose host-specific data and actions:

```swift
import PerfectAdminConsole

actor MyServer: AdminConsoleDelegate {
    var serverPort: Int { 9090 }
    var serverStartTime: Date { startedAt }
    var registeredRoutes: [RouteInfo] {
        routes.describe.map { RouteInfo(uri: $0.uri) }
    }

    func additionalStatusSections() async -> [AdminStatusSection] {
        [AdminStatusSection(title: "Database", items: [
            ("host", dbHost),
            ("pool size", "\(pool.count)"),
        ])]
    }

    func availableActions() async -> [AdminAction] {
        [AdminAction(name: "flush-cache", label: "Flush Cache",
                     description: "Evict all cached responses.", category: "maintenance")]
    }

    func executeAction(_ name: String) async throws -> AdminActionResult {
        switch name {
        case "flush-cache": cache.removeAll(); return .ok("Cache flushed")
        default: return .failed("Unknown action: \(name)")
        }
    }

    func reloadTLSCertificates() async throws {
        try await certManager.setCertificate(for: "example.com", config: loadCert())
    }
}
```

### LogCapture — feeding log lines

`LogCapture` is a Swift actor with a configurable ring buffer (default 500 lines). Integrate it with your logging stack:

```swift
let capture = LogCapture(capacity: 500)

// Manual:
await capture.capture("2026-07-14 10:00:00 [INFO] Server started")

// With swift-log via MultiplexLogHandler + a custom LogHandler that calls capture.capture(_:)
```

---

## Reference

### Server

```swift
public struct Server: Sendable {
    public var routes: Routes<HTTPRequest, HTTPOutput>
    public var host: String              // default "0.0.0.0"
    public var port: Int
    public var tls: TLSConfiguration?
    public var idleTimeout: TimeAmount?  // default .seconds(60) — nil disables
    public var reusePortCount: Int       // default 1; >1 enables SO_REUSEPORT

    public init(routes:, host:, port:, tls:, idleTimeout:, reusePortCount:)

    /// Serve until the surrounding Task is cancelled.
    public func run() async throws

    /// Bind, run body, then shut down (structured-concurrency lifecycle).
    @discardableResult
    public func withServer<R>(_ body: (_ boundPort: Int) async throws -> R) async throws -> R
}
```

`idleTimeout` closes connections that have no inbound reads for the specified duration. It is a defense against idle keep-alive connections and basic slowloris. Note: it measures *reads*, so streaming endpoints that take longer than the timeout to produce their first byte should use a larger value or `nil`.

### root()

```swift
public func root() -> Routes<HTTPRequest, HTTPRequest>
public func root<T>(_ call: @Sendable @escaping (any HTTPRequest) async throws -> T) -> Routes<HTTPRequest, T>
public func root<T>(_ call: @Sendable @escaping () async throws -> T) -> Routes<HTTPRequest, T>
public func root<T>(path: String, _ type: T.Type) -> Routes<T, T>
```

### Routes\<InType, OutType\>

```swift
@dynamicMemberLookup
public struct Routes<InType, OutType>: Sendable {
    // Instantiated only via root() or by chaining operations.
}
```

### HTTPRequest

```swift
public protocol HTTPRequest: AnyObject {
    var method: HTTPMethod { get }
    var uri: String { get }
    var headers: HTTPHeaders { get }
    var uriVariables: [String: String] { get set }
    var path: String { get }
    var searchArgs: QueryDecoder? { get }
    var contentType: String? { get }
    var contentLength: Int { get }
    var contentRead: Int { get }
    var contentConsumed: Int { get }
    var localAddress: SocketAddress? { get }
    var remoteAddress: SocketAddress? { get }
    var cookies: [String: String] { get }          // extension — parsed from Cookie header
    func readSomeContent() async throws -> [ByteBuffer]
    func readContent() async throws -> HTTPRequestContentType
}
```

### HTTPOutput

```swift
open class HTTPOutput: @unchecked Sendable {
    public init()
    open func head(request: HTTPRequestInfo) -> HTTPHead?
    open func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer?
    open func closed()
}
```

### HTTPRequestContentType

```swift
public enum HTTPRequestContentType {
    case none
    case multiPartForm(MimeReader)
    case urlForm(QueryDecoder)
    case other([UInt8])
}
```

### QueryDecoder

```swift
public struct QueryDecoder {
    public init(_ c: [UInt8])
    public subscript(_ key: String) -> [String]   // ["value"] or [] if absent
    public func map<T>(_ call: ((String, String)) throws -> T) rethrows -> [T]
    public func get(_ key: String) -> [ArraySlice<UInt8>]
}
```

Usage:

```swift
// From a URL query string
if let args = request.searchArgs {
    let ids = args["id"]   // [String]
}

// From a URL-encoded POST body
root().POST.readBody { _, content in
    guard case .urlForm(let q) = content else { return "bad" }
    return q["name"].first ?? ""
}.text()
```

### RouteError

```swift
public enum RouteError: Error {
    case duplicatedRoutes([String])
}
```

### HTTP methods

```swift
public extension Routes {
    var GET: Routes { method(.GET) }
    var POST: Routes { method(.POST) }
    var PUT: Routes { method(.PUT) }
    var DELETE: Routes { method(.DELETE) }
    var OPTIONS: Routes { method(.OPTIONS) }
    func method(_ method: HTTPMethod, _ rest: HTTPMethod...) -> Routes
}
```

### WebSocket

```swift
public enum WebSocketMessage: Sendable {
    case close
    case ping, pong
    case text(String), binary([UInt8])
}

public enum WebSocketOption: Sendable {
    case manualClose
    case manualPing
}

public protocol WebSocket: Sendable {
    var options: [WebSocketOption] { get }
    func readMessage() async throws -> WebSocketMessage
    func writeMessage(_ message: WebSocketMessage) async throws
}

public typealias WebSocketHandler = @Sendable (WebSocket) async -> Void

public extension Routes {
    func webSocket(protocol: String,
                   options: [WebSocketOption] = [],
                   _ callback: @Sendable @escaping (OutType) async throws -> WebSocketHandler)
        -> Routes<InType, HTTPOutput>
}
```

### routes.describe

Enumerate all registered route URIs (available on `Routes<HTTPRequest, HTTPOutput>`):

```swift
for desc in routes.describe {
    print(desc.uri)   // e.g. "/v1/users", "GET:///v1/users"
}
```

---

## Linux support

The PerfectNIO library is expected to compile and run on Linux — SwiftNIO is fully cross-platform, and the `CZlib` system library target includes an `apt` provider (`zlib1g-dev`).

The `platforms: [.macOS(.v15)]` entry in `Package.swift` specifies the minimum macOS deployment target only. Linux support is always implicit in SwiftPM and is not restricted by that entry.

> **Research needed:** Linux support has not been CI-verified as part of this resurrection. `URLSessionWebSocketTask` availability in `swift-corelibs-foundation` on Linux needs confirmation before the test suite can be declared Linux-clean. The `LinuxMain.swift` file was intentionally removed — Swift 5.4+ auto-discovers tests on Linux via `swift test` without it.

To build and test on Linux:

```bash
# Install system dependencies (Ubuntu/Debian)
apt-get install libssl-dev zlib1g-dev

swift build
swift test
```
