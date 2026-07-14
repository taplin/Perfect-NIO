//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// AdminAction — describes an operation the admin console can trigger on behalf
// of the operator, and the result returned after execution.
//
// Two built-in actions are always available when configured:
//   "clear-logs"  — clears the LogCapture ring buffer
//   "reload-tls"  — asks the delegate to reload TLS certificates from disk
//
// Host applications add custom actions by implementing
// AdminConsoleDelegate.availableActions() and executeAction(_:).

/// Describes a single executable action advertised to the admin console.
public struct AdminAction: Sendable {
    /// Machine-readable identifier passed back to `executeAction(_:)`. Use lowercase-kebab.
    public let name: String
    /// Short label shown on the action button.
    public let label: String
    /// Sentence describing what the action does. Shown below the label in the UI.
    public let description: String
    /// Groups actions in the UI. E.g. `"maintenance"`, `"tls"`, `"data"`, `"general"`.
    public let category: String
    /// When `true` the dashboard shows a confirmation dialog before executing.
    public let isDestructive: Bool

    public init(
        name: String,
        label: String,
        description: String,
        category: String = "general",
        isDestructive: Bool = false
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.category = category
        self.isDestructive = isDestructive
    }
}

/// The outcome of a completed action.
public struct AdminActionResult: Sendable {
    public let success: Bool
    /// Human-readable message shown as a toast notification in the admin console.
    public let message: String

    public init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }

    public static func ok(_ message: String) -> AdminActionResult {
        AdminActionResult(success: true, message: message)
    }

    public static func failed(_ message: String) -> AdminActionResult {
        AdminActionResult(success: false, message: message)
    }
}
