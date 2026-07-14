//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// LogCapture — thread-safe ring buffer for the admin console's log-tail display.
//
// Usage:
//   let capture = LogCapture()
//   // Feed lines from wherever the app produces log output:
//   await capture.capture("2026-07-14 10:00:00 [INFO] Server started")
//
// Perfect-Logger / swift-log integration: wrap LogCapture in a custom LogHandler
// that calls capture.capture() for each log entry, then multiplex it alongside
// the existing handler via MultiplexLogHandler.
//
// The capacity defaults to 500 lines. Once full, the oldest line is dropped to
// make room for each new one.

/// Thread-safe ring buffer for admin console log display.
public actor LogCapture {
    private let capacity: Int
    private var lines: [String] = []

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    /// Append a formatted log line. Call from any async context.
    public func capture(_ message: String) {
        if lines.count >= capacity {
            lines.removeFirst()
        }
        lines.append(message)
    }

    /// Returns the last `count` lines, oldest first. Thread-safe.
    public func recentLines(count: Int = 100) -> [String] {
        let n = min(count, lines.count)
        let start = lines.count - n
        return Array(lines[start...])
    }

    /// Total lines captured since this instance was created (including overwritten ones).
    public var totalCaptured: Int { lines.count }
}
