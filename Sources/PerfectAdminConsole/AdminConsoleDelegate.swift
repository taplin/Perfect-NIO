//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// AdminConsoleDelegate — protocol for the host application to supply live
// server state to the admin console's status, route, and action displays.
//
// All methods have default no-op implementations: conformance is additive.
// The host implements only what it wants to expose.
//
// Phase 1: status sections, route inspector
// Phase 2: custom actions, TLS certificate reload

import Foundation

/// A single route visible in the admin console's route inspector.
public struct RouteInfo: Sendable {
    public let uri: String
    public init(uri: String) { self.uri = uri }
}

/// A key-value section contributed by the host to the admin status page.
/// Use for application-specific info (e.g. Lasso startup results, datasource alias map).
public struct AdminStatusSection: Sendable {
    public let title: String
    public let items: [(key: String, value: String)]

    public init(title: String, items: [(key: String, value: String)]) {
        self.title = title
        self.items = items
    }
}

/// Protocol for the host application to supply live server state to the admin console.
/// Conformers must be `Sendable`; actors satisfy this automatically.
public protocol AdminConsoleDelegate: AnyObject, Sendable {
    // MARK: Phase 1 — status display

    /// The port the main application server is listening on. Return 0 to omit.
    var serverPort: Int { get }
    /// When the server process started — used for uptime display.
    var serverStartTime: Date { get }
    /// Routes registered on the main server, for the route inspector.
    var registeredRoutes: [RouteInfo] { get }
    /// Optional extra sections shown below the standard status cards.
    func additionalStatusSections() async -> [AdminStatusSection]

    // MARK: Phase 2 — actions

    /// Custom actions offered by this host. Combined with built-in actions in the console.
    /// Return an empty array (default) to suppress the actions panel.
    func availableActions() async -> [AdminAction]

    // MARK: Phase 3 — datasource management

    /// All datasource connections to surface in the admin console.
    /// Return only sanitized info: alias + schema name, **never** credentials.
    func registeredDatasources() async -> [DatasourceInfo]

    /// Test a specific named datasource connection on demand.
    ///
    /// Only called for `name` values returned by `registeredDatasources()`.
    /// Return `.failed("reason")` rather than throwing — that produces a clean
    /// toast notification rather than a 500 error in the UI.
    func testDatasource(name: String) async throws -> DatasourceTestResult

    /// Execute a custom action by name. Only called for names returned by `availableActions()`.
    /// Return `.failed` rather than throwing to send a friendly error message to the UI.
    func executeAction(_ name: String) async throws -> AdminActionResult

    /// Called when the operator triggers the built-in "reload-tls" action.
    /// Implement to re-read certificate PEM files and push them to your `TLSContextManager`.
    /// Default implementation is a no-op (the built-in action will report success silently).
    func reloadTLSCertificates() async throws
}

public extension AdminConsoleDelegate {
    var serverPort: Int { 0 }
    var serverStartTime: Date { .distantFuture }
    var registeredRoutes: [RouteInfo] { [] }
    func additionalStatusSections() async -> [AdminStatusSection] { [] }
    func availableActions() async -> [AdminAction] { [] }
    func executeAction(_ name: String) async throws -> AdminActionResult {
        .failed("Unknown action: \(name)")
    }
    func reloadTLSCertificates() async throws {}
    func registeredDatasources() async -> [DatasourceInfo] { [] }
    func testDatasource(name: String) async throws -> DatasourceTestResult {
        .failed("No datasource named '\(name)' is registered")
    }
}
