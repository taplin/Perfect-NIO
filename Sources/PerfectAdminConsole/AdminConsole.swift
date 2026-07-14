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
// Phase 1: status card, TLS domain list, ACME challenge count,
//          log tail (ring buffer), and route inspector via delegate.
// Phase 2: CSRF protection on mutating routes, actions framework
//          (GET /api/actions, POST /api/actions), log buffer clear (DELETE /api/logs),
//          audit trail written to LogCapture.
// Phase 3: Datasource management — GET /api/datasources, POST /api/datasources/test.
//          DatasourceInfo (sanitized, no credentials) + on-demand ping via delegate.
// Phase 4: In-process metrics (GET /api/metrics via AdminMetrics actor),
//          per-domain TLS ops (POST /api/tls/reload, DELETE /api/tls/domain).
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
    private let metrics: AdminMetrics?
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
        metrics: AdminMetrics? = nil,
        delegate: (any AdminConsoleDelegate)? = nil
    ) throws {
        self.port = port
        self.tokenStore = try AdminTokenStore(tokenFilePath: tokenFilePath)
        self.tlsManager = tlsManager
        self.acmeResponder = acmeResponder
        self.logCapture = logCapture
        self.metrics = metrics
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
        let metrics = self.metrics
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

        // ── Phase 3: datasource management ───────────────────────────────────

        // GET /api/datasources — list all registered datasources (sanitized, no credentials)
        let datasourcesRoute = root().GET.path("api").path("datasources").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            let sources = await delegate?.registeredDatasources() ?? []
            struct DSEnc: Encodable { let name, alias, schema, driver: String }
            struct DSListEnc: Encodable { let datasources: [DSEnc] }
            return try JSONOutput(DSListEnc(datasources: sources.map {
                DSEnc(name: $0.name, alias: $0.alias, schema: $0.schema, driver: $0.driver)
            }))
        }

        // POST /api/datasources/test — ping a named datasource on demand
        let datasourceTestRoute = root().POST.path("api").path("datasources").path("test").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            try requireCSRF(headers: req.headers, port: adminPort)
            let bytes = try await adminReadJSONBody(req)
            struct Body: Decodable { let name: String }
            let body = try JSONDecoder().decode(Body.self, from: Data(bytes))
            let result: DatasourceTestResult
            if let del = delegate {
                result = (try? await del.testDatasource(name: body.name)) ?? .failed("Test threw an unexpected error")
            } else {
                result = .failed("No delegate configured")
            }
            await logCapture?.capture("[admin] datasource-test name=\(body.name) success=\(result.success): \(result.message)")
            struct ResultEnc: Encodable { let success: Bool; let message: String; let latencyMs: Double? }
            return try JSONOutput(ResultEnc(success: result.success, message: result.message, latencyMs: result.latencyMs))
        }

        // ── Phase 2: mutating routes ──────────────────────────────────────────

        // GET /api/actions — list built-in + delegate actions
        let actionsGetRoute = root().GET.path("api").path("actions").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            let builtins = adminBuiltinActions(hasLogs: logCapture != nil, hasDelegate: delegate != nil)
            let custom = await delegate?.availableActions() ?? []
            struct ActionEnc: Encodable {
                let name, label, description, category: String
                let isDestructive: Bool
            }
            struct ActionsEnc: Encodable { let actions: [ActionEnc] }
            let all = (builtins + custom).map {
                ActionEnc(name: $0.name, label: $0.label, description: $0.description,
                          category: $0.category, isDestructive: $0.isDestructive)
            }
            return try JSONOutput(ActionsEnc(actions: all))
        }

        // POST /api/actions — execute an action by name
        let actionsPostRoute = root().POST.path("api").path("actions").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            try requireCSRF(headers: req.headers, port: adminPort)
            let bytes = try await adminReadJSONBody(req)
            struct Body: Decodable { let action: String }
            let body = try JSONDecoder().decode(Body.self, from: Data(bytes))

            let result: AdminActionResult
            switch body.action {
            case "clear-logs":
                let dropped = await logCapture?.clear() ?? 0
                result = .ok("Log buffer cleared — \(dropped) line\(dropped == 1 ? "" : "s") dropped")
            case "reload-tls":
                do {
                    try await delegate?.reloadTLSCertificates()
                    result = .ok("TLS certificates reloaded")
                } catch {
                    result = .failed("TLS reload failed: \(error.localizedDescription)")
                }
            default:
                guard let del = delegate else {
                    throw ErrorOutput(status: .notFound, description: "Unknown action: \(body.action)")
                }
                result = try await del.executeAction(body.action)
            }

            await logCapture?.capture("[admin] action=\(body.action) success=\(result.success): \(result.message)")

            struct ResultEnc: Encodable { let success: Bool; let message: String }
            return try JSONOutput(ResultEnc(success: result.success, message: result.message))
        }

        // DELETE /api/logs — clear the log ring buffer immediately
        let clearLogsRoute = root().DELETE.path("api").path("logs").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            try requireCSRF(headers: req.headers, port: adminPort)
            let dropped = await logCapture?.clear() ?? 0
            await logCapture?.capture("[admin] log buffer cleared — \(dropped) line\(dropped == 1 ? "" : "s") dropped")
            struct ClearEnc: Encodable { let dropped: Int }
            return try JSONOutput(ClearEnc(dropped: dropped))
        }

        // ── Phase 4: metrics + TLS operations ────────────────────────────────

        // GET /api/metrics — lightweight request counters snapshot
        let metricsRoute = root().GET.path("api").path("metrics").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            let snap = await metrics?.snapshot() ?? MetricsSnapshot(
                totalRequests: 0, totalErrors: 0, activeConnections: 0, routeCounts: [:]
            )
            return try JSONOutput(snap)
        }

        // POST /api/tls/reload — hot-reload cert for a specific hostname via delegate
        let tlsReloadRoute = root().POST.path("api").path("tls").path("reload").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            try requireCSRF(headers: req.headers, port: adminPort)
            let bytes = try await adminReadJSONBody(req)
            struct Body: Decodable { let hostname: String }
            let body = try JSONDecoder().decode(Body.self, from: Data(bytes))
            struct ResultEnc: Encodable { let success: Bool; let message: String }
            do {
                try await delegate?.reloadTLSCertificate(for: body.hostname)
                await logCapture?.capture("[admin] tls-reload hostname=\(body.hostname) success")
                return try JSONOutput(ResultEnc(success: true, message: "TLS certificate reloaded for \(body.hostname)"))
            } catch {
                await logCapture?.capture("[admin] tls-reload hostname=\(body.hostname) failed: \(error)")
                return try JSONOutput(ResultEnc(success: false, message: error.localizedDescription))
            }
        }

        // DELETE /api/tls/domain — remove a hostname's cert from the live TLS map
        let tlsRemoveRoute = root().DELETE.path("api").path("tls").path("domain").map { (req: any HTTPRequest) async throws -> HTTPOutput in
            try tokenStore.requireAuth(from: req.headers)
            try requireCSRF(headers: req.headers, port: adminPort)
            let bytes = try await adminReadJSONBody(req)
            struct Body: Decodable { let hostname: String }
            let body = try JSONDecoder().decode(Body.self, from: Data(bytes))
            guard let mgr = tlsManager else {
                throw ErrorOutput(status: .serviceUnavailable, description: "No TLS manager configured")
            }
            await mgr.removeCertificate(for: body.hostname)
            await logCapture?.capture("[admin] tls-remove hostname=\(body.hostname)")
            struct ResultEnc: Encodable { let success: Bool; let message: String }
            return try JSONOutput(ResultEnc(success: true, message: "TLS configuration removed for \(body.hostname)"))
        }

        return try root().dir(uiRoute, statusRoute, tlsRoute, acmeRoute, logsRoute, routesRoute,
                              datasourcesRoute, datasourceTestRoute,
                              metricsRoute, tlsReloadRoute, tlsRemoveRoute,
                              actionsGetRoute, actionsPostRoute, clearLogsRoute)
    }
}

// MARK: - Internal helpers (internal so tests can reach them via @testable import)

/// Built-in actions always offered by the admin console (when the relevant subsystem is configured).
func adminBuiltinActions(hasLogs: Bool, hasDelegate: Bool) -> [AdminAction] {
    var actions: [AdminAction] = []
    if hasLogs {
        actions.append(AdminAction(
            name: "clear-logs",
            label: "Clear Log Buffer",
            description: "Remove all lines from the in-memory log ring buffer.",
            category: "maintenance",
            isDestructive: true
        ))
    }
    if hasDelegate {
        actions.append(AdminAction(
            name: "reload-tls",
            label: "Reload TLS Certificates",
            description: "Ask the host to reload TLS certificates from disk without restarting.",
            category: "tls",
            isDestructive: false
        ))
    }
    return actions
}

/// Reads the full request body and returns it as raw bytes.
/// Content-type must be `application/json`; other types return empty bytes without error
/// so the downstream decoder produces a clean `DecodingError`.
func adminReadJSONBody(_ req: any HTTPRequest) async throws -> [UInt8] {
    let content = try await req.readContent()
    if case .other(let bytes) = content { return bytes }
    return []
}
