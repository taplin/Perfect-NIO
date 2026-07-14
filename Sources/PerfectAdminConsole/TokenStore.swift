//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// AdminTokenStore — generates a cryptographically random bearer token, writes
// it to a caller-specified path (chmod 600), and validates incoming tokens
// with a constant-time comparison to prevent timing oracles.

import Foundation
import PerfectNIO

struct AdminTokenStore: Sendable {
    let token: String
    let filePath: String

    init(tokenFilePath: String) throws {
        filePath = tokenFilePath
        // 32 random bytes → 64 lowercase hex chars
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        token = bytes.map { String(format: "%02x", $0) }.joined()

        let url = URL(fileURLWithPath: tokenFilePath)
        try (token + "\n").write(to: url, atomically: true, encoding: .utf8)
        // chmod 600: owner read+write only — other processes on the same machine
        // can still hit the localhost admin port, but they can't read the token file.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tokenFilePath
        )
    }

    /// Extracts and validates the bearer token from an HTTP Authorization header.
    /// Throws `ErrorOutput(.unauthorized)` on any failure so the caller can just `try`.
    func requireAuth(from headers: HTTPHeaders) throws {
        let header = headers.first(name: "Authorization") ?? ""
        guard header.lowercased().hasPrefix("bearer ") else {
            throw ErrorOutput(status: .unauthorized, description: "Missing Authorization: Bearer header")
        }
        let candidate = String(header.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        guard constantTimeEqual(candidate, token) else {
            throw ErrorOutput(status: .unauthorized, description: "Invalid token")
        }
    }

    // XOR-fold all byte pairs — same cost regardless of where the first mismatch is.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        return zip(ab, bb).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
