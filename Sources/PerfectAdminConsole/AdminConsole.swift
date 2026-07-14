//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// AdminConsole — lightweight read-only admin server bound to 127.0.0.1 only.
//
// Phase 1 features: status card, TLS domain list, ACME challenge count,
// log tail (ring buffer), and route inspector via delegate.
//
// Security model:
//   - Binds exclusively to 127.0.0.1; no configuration option to change this.
//   - All /api/* routes require Authorization: Bearer <token>.
//   - Token is generated at startup and written to a caller-specified path
//     (chmod 600). Operators access it via: cat <path>
//   - HTML shell (GET /) is served without auth so the browser can show the
//     token-entry form; all data fetches are auth-gated.
//   - Phase 1 routes are all read-only; CSRF protection is added in Phase 2
//     alongside the first mutating operations (cert reload, connection test).
//
// Usage:
//   let capture = LogCapture()
//   let admin = try AdminConsole(
//       port: 8990,
//       tokenFilePath: "/var/run/perfect-admin.token",
//       tlsManager: certManager,
//       acmeResponder: acme,
//       logCapture: capture,
//       delegate: myServer
//   )
//   async let _ = admin.run()

import Foundation
import PerfectNIO

public actor AdminConsole {

    private let port: Int
    private let tokenStore: AdminTokenStore
    private let tlsManager: TLSContextManager?
    private let acmeResponder: ACMEChallengeResponder?
    private let logCapture: LogCapture?
    private let delegate: (any AdminConsoleDelegate)?

    /// - Parameters:
    ///   - port: Port for the admin server. Default 8990.
    ///   - tokenFilePath: Path where the generated bearer token is written (chmod 600).
    ///     Example: `/var/run/myapp-admin.token` or `$TMPDIR/myapp-admin.token`.
    ///   - tlsManager: The live TLS manager from the main server, for cert status display.
    ///   - acmeResponder: The ACME challenge store, for pending-challenge display.
    ///   - logCapture: Ring buffer that the host feeds log lines into; `nil` means no log tail.
    ///   - delegate: Optional hook for host-specific status sections and route list.
    public init(
        port: Int = 8990,
        tokenFilePath: String,
        tlsManager: TLSContextManager? = nil,
        acmeResponder: ACMEChallengeResponder? = nil,
        logCapture: LogCapture? = nil,
        delegate: (any AdminConsoleDelegate)? = nil
    ) throws {
        self.port = port
        self.tokenStore = try AdminTokenStore(tokenFilePath: tokenFilePath)
        self.tlsManager = tlsManager
        self.acmeResponder = acmeResponder
        self.logCapture = logCapture
        self.delegate = delegate
    }

    /// Bind and serve until the surrounding task is cancelled.
    /// Prints the admin URL and token file path to stderr on startup.
    public func run() async throws {
        let routes = try buildRoutes()
        let server = Server(routes: routes, host: "127.0.0.1", port: port)
        fputs("[AdminConsole] http://127.0.0.1:\(port) — token: \(tokenStore.filePath)\n", stderr)
        try await server.run()
    }

    // MARK: - Route building

    private func buildRoutes() throws -> Routes<HTTPRequest, HTTPOutput> {
        // Capture all dependencies by value (Sendable) so the @Sendable route
        // closures below don't retain `self` and don't need actor isolation.
        let tokenStore = self.tokenStore
        let tlsManager = self.tlsManager
        let acmeResponder = self.acmeResponder
        let logCapture = self.logCapture
        let delegate = self.delegate
        let adminPort = self.port

        // GET / — HTML shell, no auth (the page has its own token-entry form)
        let uiRoute = root().GET.map { (_: any HTTPRequest) async throws -> HTTPOutput in
            AdminWebUI.response(tokenFilePath: tokenStore.filePath)
        }

        // GET /api/status — server summary card
        let statusRoute = root().GET.path("api").path("status").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            let domains = await tlsManager?.registeredHostnames() ?? []
            let hasDefault = await tlsManager?.hasDefaultContext ?? false
            let pendingACME = await acmeResponder?.pendingCount ?? 0
            let serverPort = delegate?.serverPort
            let uptimeSecs: Double?
            if let start = delegate?.serverStartTime, start < Date() {
                uptimeSecs = Date().timeIntervalSince(start)
            } else {
                uptimeSecs = nil
            }
            let extraSections = await delegate?.additionalStatusSections() ?? []

            struct SectionEnc: Encodable {
                let title: String
                let items: [String: String]
            }
            struct StatusEnc: Encodable {
                let adminPort: Int
                let serverPort: Int?
                let uptimeSeconds: Double?
                let tlsDomainCount: Int
                let tlsHasDefault: Bool
                let acmePendingChallenges: Int
                let additionalSections: [SectionEnc]
            }
            let resp = StatusEnc(
                adminPort: adminPort,
                serverPort: (serverPort ?? 0) != 0 ? serverPort : nil,
                uptimeSeconds: uptimeSecs,
                tlsDomainCount: domains.count,
                tlsHasDefault: hasDefault,
                acmePendingChallenges: pendingACME,
                additionalSections: extraSections.map {
                    SectionEnc(title: $0.title, items: Dictionary(uniqueKeysWithValues: $0.items))
                }
            )
            return try JSONOutput(resp)
        }

        // GET /api/tls — per-domain cert list
        let tlsRoute = root().GET.path("api").path("tls").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            let domains = await tlsManager?.registeredHostnames() ?? []
            let hasDefault = await tlsManager?.hasDefaultContext ?? false
            struct TLSEnc: Encodable { let domains: [String]; let hasDefault: Bool }
            return try JSONOutput(TLSEnc(domains: domains, hasDefault: hasDefault))
        }

        // GET /api/acme — pending ACME challenge count
        let acmeRoute = root().GET.path("api").path("acme").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            let count = await acmeResponder?.pendingCount ?? 0
            struct ACMEEnc: Encodable { let pendingChallenges: Int }
            return try JSONOutput(ACMEEnc(pendingChallenges: count))
        }

        // GET /api/logs?count=N — recent log lines from the ring buffer
        let logsRoute = root().GET.path("api").path("logs").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            let countParam = req.searchArgs?["count"].first.flatMap(Int.init) ?? 100
            let count = max(1, min(countParam, 500))
            let lines = await logCapture?.recentLines(count: count) ?? []
            let total = await logCapture?.totalCaptured ?? 0
            struct LogsEnc: Encodable { let lines: [String]; let totalCaptured: Int }
            return try JSONOutput(LogsEnc(lines: lines, totalCaptured: total))
        }

        // GET /api/routes — route list from delegate
        let routesRoute = root().GET.path("api").path("routes").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            let uris = delegate?.registeredRoutes.map(\.uri) ?? []
            struct RoutesEnc: Encodable { let routes: [String] }
            return try JSONOutput(RoutesEnc(routes: uris))
        }

        return try root().dir(uiRoute, statusRoute, tlsRoute, acmeRoute, logsRoute, routesRoute)
    }
}
