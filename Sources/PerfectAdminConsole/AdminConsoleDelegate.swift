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
// server state to the admin console's status and route displays.
//
// All methods have default no-op implementations: conformance is additive.
// The host implements only what it wants to expose.

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
    /// The port the main application server is listening on. Return 0 to omit.
    var serverPort: Int { get }
    /// When the server process started — used for uptime display.
    var serverStartTime: Date { get }
    /// Routes registered on the main server, for the route inspector.
    var registeredRoutes: [RouteInfo] { get }
    /// Optional extra sections shown below the standard status cards.
    func additionalStatusSections() async -> [AdminStatusSection]
}

public extension AdminConsoleDelegate {
    var serverPort: Int { 0 }
    var serverStartTime: Date { .distantFuture }
    var registeredRoutes: [RouteInfo] { [] }
    func additionalStatusSections() async -> [AdminStatusSection] { [] }
}
