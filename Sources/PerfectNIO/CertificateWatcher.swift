//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// Watches a Let's Encrypt (or manually managed) cert directory and hot-reloads
// into TLSContextManager whenever the files change.
//
// Typical Let's Encrypt layout (per-domain):
//   /etc/letsencrypt/live/<domain>/
//     fullchain.pem  → ../archive/<domain>/fullchainN.pem
//     privkey.pem    → ../archive/<domain>/privkeyN.pem
//
// On renewal, certbot atomically updates those symlinks. The directory itself
// receives a write event (DispatchSource.EventTypeFlags.write) which triggers
// a reload. The open fd is held on the directory, so the watch survives the
// symlink swap.
//
// One CertificateWatcher per domain. Create and start after building the
// TLSContextManager, before calling Server.run().
//
// Usage:
//   let watcher = CertificateWatcher(
//       hostname: "example.com",
//       directory: "/etc/letsencrypt/live/example.com",
//       manager: certManager)
//   try await watcher.start()
//   // ...later, on shutdown:
//   watcher.stop()

import Foundation
import NIOSSL

/// Watches a cert directory and keeps TLSContextManager up to date.
///
/// `@unchecked Sendable`: the mutable `source` property is written once in
/// `watch()` (called from `start()`) and read once in `stop()`. Callers are
/// expected to call those two methods in a non-concurrent fashion.
public final class CertificateWatcher: @unchecked Sendable {
	private let hostname: String
	private let directory: URL
	private let manager: TLSContextManager
	private var source: DispatchSourceFileSystemObject?

	/// - Parameters:
	///   - hostname: The SNI hostname this cert covers. Must match the key used in
	///     `TLSContextManager.setCertificate(for:config:)`.
	///   - directory: Path to the directory containing `fullchain.pem` and `privkey.pem`.
	///   - manager: The live cert manager to update when the cert files change.
	public init(hostname: String, directory: String, manager: TLSContextManager) {
		self.hostname = hostname
		self.directory = URL(fileURLWithPath: directory, isDirectory: true)
		self.manager = manager
	}

	/// Load the initial cert, then begin watching for changes.
	///
	/// Call this once after creating the watcher, before starting the server.
	/// Subsequent reloads are automatic.
	public func start() async throws {
		try await reload()
		watch()
	}

	/// Cancel the directory watch. Call during graceful shutdown.
	public func stop() {
		source?.cancel()
		source = nil
	}

	// MARK: -

	private func watch() {
		let path = directory.path
		let fd = open(path, O_RDONLY)
		guard fd >= 0 else { return }

		let src = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: fd,
			eventMask: [.write, .rename, .delete],
			queue: .global(qos: .utility)
		)
		src.setEventHandler { [weak self] in
			guard let self else { return }
			Task { try? await self.reload() }
		}
		src.setCancelHandler { close(fd) }
		src.resume()
		source = src
	}

	private func reload() async throws {
		let certPath = directory.appendingPathComponent("fullchain.pem").path
		let keyPath  = directory.appendingPathComponent("privkey.pem").path
		let certs = try NIOSSLCertificate.fromPEMFile(certPath)
		let key   = try NIOSSLPrivateKey(file: keyPath, format: .pem)
		let config = TLSConfiguration.makeServerConfiguration(
			certificateChain: certs.map { .certificate($0) },
			privateKey: .privateKey(key)
		)
		try await manager.setCertificate(for: hostname, config: config)
	}
}
