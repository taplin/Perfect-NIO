//
//  Server.swift
//  PerfectNIO
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2019 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//
// Phase 5: the async-native server API. Replaces the synchronous
// bind().listen()/stop()/wait() surface (and its async→sync bridge) with a
// structured-concurrency `Server`. The connection-handling serve loop itself
// lives in NIOAsyncHTTPHandler.swift (Phase 4) and is reused unchanged.
//

import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOConcurrencyHelpers
import Foundation

typealias HTTPConnectionChannel = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
typealias HTTPServerChannel = NIOAsyncChannel<HTTPConnectionChannel, Never>

/// An HTTP(S) server for a set of routes.
///
/// ```swift
/// // Long-running:
/// try await Server(routes: myRoutes, port: 8080).run()
///
/// // Scoped (tests / programmatic):
/// try await Server(routes: myRoutes, port: 8080).withServer { port in
///     // ...make requests against `port`; server shuts down when this returns...
/// }
/// ```
public struct Server: Sendable {
	/// The routes this server will serve.
	public var routes: Routes<HTTPRequest, HTTPOutput>
	/// The host/interface to bind on. Defaults to all interfaces.
	public var host: String
	/// The port to bind on. Pass 0 for an OS-assigned ephemeral port (see `withServer`'s argument).
	public var port: Int
	/// TLS configuration. When non-nil the server speaks HTTPS.
	public var tls: TLSConfiguration?
	/// Closes a connection after this much time with no inbound read. `nil` disables the timeout.
	///
	/// This bounds idle keep-alive connections (resource-exhaustion / basic slowloris defense).
	/// Note: it measures *reads*, so a route handler that takes longer than this to produce its
	/// first byte on an otherwise-quiet connection will have the connection closed — give streaming
	/// / long-poll endpoints a larger value or `nil`. Full slow-trickle slowloris mitigation
	/// (a whole-request deadline) is a separate, later hardening step.
	public var idleTimeout: TimeAmount?
	/// Number of server sockets to open on the same port via `SO_REUSEPORT` (kernel load-balances
	/// accepts across them). 1 = a single socket with no `SO_REUSEPORT`.
	public var reusePortCount: Int

	public init(routes: Routes<HTTPRequest, HTTPOutput>,
	            host: String = "0.0.0.0",
	            port: Int,
	            tls: TLSConfiguration? = nil,
	            idleTimeout: TimeAmount? = .seconds(60),
	            reusePortCount: Int = 1) {
		self.routes = routes
		self.host = host
		self.port = port
		self.tls = tls
		self.idleTimeout = idleTimeout
		self.reusePortCount = reusePortCount
	}

	/// Bind and serve until the surrounding task is cancelled, then gracefully drain in-flight
	/// connections and shut down the owned EventLoopGroup. Intended for an application's entry point.
	public func run() async throws {
		try await serve { _ in
			// Park until the surrounding task is cancelled — cancellation is the shutdown signal.
			// Task.sleep throws on cancellation, so the loop exits promptly and serve() tears down.
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(3600))
			}
		}
	}

	/// Bind, invoke `body` once the server is listening (passing the actually-bound port), then
	/// shut the server down — on normal return, on a thrown error, or on cancellation. The
	/// structured-concurrency replacement for start/stop; teardown (including EventLoopGroup
	/// shutdown) is automatic and awaited.
	@discardableResult
	public func withServer<R>(_ body: (_ boundPort: Int) async throws -> R) async throws -> R {
		// Captured out of the serve task; only read after `body` runs (i.e. after binding).
		let resultBox = NIOLockedValueBox<Result<R, Error>?>(nil)
		try await serve { boundPort in
			let outcome: Result<R, Error>
			do { outcome = .success(try await body(boundPort)) }
			catch { outcome = .failure(error) }
			resultBox.withLockedValue { $0 = outcome }
		}
		// serve() only returns after onReady completed (or binding failed before it ran).
		guard let result = resultBox.withLockedValue({ $0 }) else {
			throw ServerError("server stopped before it finished binding on port \(port)")
		}
		return try result.get()
	}

	// MARK: - Core

	/// Owns the full server lifecycle: bind N channels, run their accept loops, invoke `onReady`
	/// once listening, and tear everything down (channels + EventLoopGroup) when `onReady` returns.
	private func serve(onReady: (_ boundPort: Int) async throws -> Void) async throws {
		_ = processGlobalInit
		let finder = try RouteFinderDual(routes)
		let isTLS = tls != nil
		let sslContext = try tls.map { try NIOSSLContext(configuration: $0) }
		let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

		func shutdown() async { try? await group.shutdownGracefully() }

		do {
			let channels = try await bind(group: group, sslContext: sslContext)
			let boundPort = channels.first?.channel.localAddress?.port ?? port
			try await withThrowingTaskGroup(of: Void.self) { acceptors in
				for channel in channels {
					acceptors.addTask {
						await Server.runAcceptLoop(channel, finder: finder, isTLS: isTLS)
					}
				}
				// Run the caller's work, then stop accepting. A throw here auto-cancels the
				// acceptor tasks; on success we cancel them explicitly.
				do {
					try await onReady(boundPort)
				} catch {
					acceptors.cancelAll()
					throw error
				}
				acceptors.cancelAll()
			}
			await shutdown()
		} catch {
			await shutdown()
			throw error
		}
	}

	/// Binds `reusePortCount` server channels on the configured host/port.
	private func bind(group: MultiThreadedEventLoopGroup,
	                  sslContext: NIOSSLContext?) async throws -> [HTTPServerChannel] {
		let count = max(1, reusePortCount)
		let reusePort = count > 1
		let idle = idleTimeout
		let host = self.host
		let port = self.port

		var channels: [HTTPServerChannel] = []
		channels.reserveCapacity(count)
		for _ in 0..<count {
			var bootstrap = ServerBootstrap(group: group)
				.serverChannelOption(ChannelOptions.backlog, value: 256)
				.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
			if reusePort {
				bootstrap = bootstrap.serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
			}
			bootstrap = bootstrap
				.childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
				.childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
				.childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
			let channel = try await bootstrap.bind(host: host, port: port) { childChannel in
				childChannel.eventLoop.makeCompletedFuture {
					if let sslContext = sslContext {
						try childChannel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
					}
					try childChannel.pipeline.syncOperations.configureHTTPServerPipeline()
					if let idle = idle {
						try childChannel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: idle))
						try childChannel.pipeline.syncOperations.addHandler(IdleTimeoutHandler())
					}
					return try HTTPConnectionChannel(wrappingChannelSynchronously: childChannel)
				}
			}
			channels.append(channel)
		}
		return channels
	}

	/// Accept loop for one server channel: each accepted connection is handled in its own child
	/// task so slow clients never block accepts. Returns when the channel closes or on cancellation.
	private static func runAcceptLoop(_ serverChannel: HTTPServerChannel,
	                                  finder: any RouteFinder,
	                                  isTLS: Bool) async {
		do {
			try await withThrowingDiscardingTaskGroup { connections in
				try await serverChannel.executeThenClose { inbound in
					for try await connectionChannel in inbound {
						connections.addTask {
							await NIOAsyncHTTPServer.handleConnection(connectionChannel, finder: finder, isTLS: isTLS)
						}
					}
				}
			}
		} catch {
			// Server channel closed (cancellation / shutdown) or the accept loop failed.
		}
	}
}

/// An error originating from the server lifecycle.
public struct ServerError: Error, CustomStringConvertible {
	public let description: String
	init(_ description: String) { self.description = description }
}

/// Closes a connection when `IdleStateHandler` reports it idle. Sits directly after the
/// `IdleStateHandler` in the pipeline; constructed on the event loop, never shared.
private final class IdleTimeoutHandler: ChannelInboundHandler {
	typealias InboundIn = NIOAny
	func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
		if event is IdleStateHandler.IdleStateEvent {
			context.close(promise: nil)
		} else {
			context.fireUserInboundEventTriggered(event)
		}
	}
}

/// One-time process setup: ignore SIGPIPE and raise the open-file limit. Runs on first server bind.
private let processGlobalInit: Bool = {
	var sa = sigaction()
#if os(Linux)
	sa.__sigaction_handler.sa_handler = SIG_IGN
#else
	sa.__sigaction_u.__sa_handler = SIG_IGN
#endif
	sa.sa_flags = 0
	sigaction(SIGPIPE, &sa, nil)
	var rlmt = rlimit()
#if os(Linux)
	getrlimit(Int32(RLIMIT_NOFILE.rawValue), &rlmt)
	rlmt.rlim_cur = rlmt.rlim_max
	setrlimit(Int32(RLIMIT_NOFILE.rawValue), &rlmt)
#else
	getrlimit(RLIMIT_NOFILE, &rlmt)
	rlmt.rlim_cur = rlim_t(OPEN_MAX)
	setrlimit(RLIMIT_NOFILE, &rlmt)
#endif
	return true
}()
