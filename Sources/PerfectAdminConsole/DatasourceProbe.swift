//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// DatasourceProbe — sanitized connection descriptor and on-demand test result.
//
// Host applications supply DatasourceInfo objects via AdminConsoleDelegate
// to make their datasource connections visible in the admin console without
// exposing credentials.  The host also implements testDatasource(name:) to
// run a real connectivity check when the operator clicks "Test" in the UI.
//
// Credentials must never appear in DatasourceInfo.  Only pass alias, schema
// name, and driver type — information that is safe to display to the operator.

import Foundation

/// Sanitized description of one datasource connection.
///
/// **No password or host credentials.** Return only what is safe to display
/// to an operator who has already authenticated to the admin console.
public struct DatasourceInfo: Sendable {
    /// Unique key used in `AdminConsoleDelegate.testDatasource(name:)`.
    /// Use a stable, lowercase-kebab identifier (e.g. `"mysql-main"`, `"redis-cache"`).
    public let name: String
    /// Human-readable label shown in the UI — e.g. a Lasso alias or environment variable name.
    public let alias: String
    /// Database or schema name. For FileMaker, the file name. For Redis, the db index as a string.
    public let schema: String
    /// Driver type label — e.g. `"MySQL"`, `"PostgreSQL"`, `"Redis"`, `"FileMaker"`, `"SQLite"`.
    public let driver: String

    public init(name: String, alias: String, schema: String, driver: String) {
        self.name = name
        self.alias = alias
        self.schema = schema
        self.driver = driver
    }
}

/// The outcome of an on-demand datasource connectivity test.
public struct DatasourceTestResult: Sendable {
    public let success: Bool
    /// Human-readable status message shown as a toast and in the log tail.
    public let message: String
    /// Round-trip latency of the test query, if the test completed. `nil` on failure before a response.
    public let latencyMs: Double?

    public init(success: Bool, message: String, latencyMs: Double? = nil) {
        self.success = success
        self.message = message
        self.latencyMs = latencyMs
    }

    /// Convenience factory for a successful test.
    public static func ok(latencyMs: Double? = nil, message: String = "Connection OK") -> DatasourceTestResult {
        DatasourceTestResult(success: true, message: message, latencyMs: latencyMs)
    }

    /// Convenience factory for a failed test.
    public static func failed(_ message: String) -> DatasourceTestResult {
        DatasourceTestResult(success: false, message: message, latencyMs: nil)
    }
}
