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
import NIOWebSocket
import NIOConcurrencyHelpers
import Foundation

typealias HTTPConnectionChannel = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
typealias WebSocketConnectionChannel = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
// Each accepted connection resolves to one of these once the HTTP-upgrade decision is made.
// The server channel yields the *futures* so the accept loop never blocks on a slow handshake.
typealias HTTPServerChannel = NIOAsyncChannel<EventLoopFuture<HTTPOrWebSocket>, Never>

/// The outcome of the HTTP-upgrade negotiation for one connection.
enum HTTPOrWebSocket: Sendable {
	case http(HTTPConnectionChannel)
	case websocket(WebSocketConnectionChannel, WebSocketHandler, [WebSocketOption])
}

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
			let channels = try await bind(group: group, sslContext: sslContext, finder: finder, isTLS: isTLS)
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

	/// Binds `reusePortCount` server channels on the configured host/port. Each child channel is
	/// configured with an HTTP pipeline that can upgrade to WebSocket (see `configureUpgrade`).
	private func bind(group: MultiThreadedEventLoopGroup,
	                  sslContext: NIOSSLContext?,
	                  finder: any RouteFinder,
	                  isTLS: Bool) async throws -> [HTTPServerChannel] {
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
					return try Server.configureUpgrade(channel: childChannel, finder: finder, isTLS: isTLS, idleTimeout: idle)
				}
			}
			channels.append(channel)
		}
		return channels
	}

	/// Configures the child channel's HTTP pipeline with a WebSocket upgrader. Returns the future
	/// that resolves to either a normal HTTP connection or an upgraded WebSocket connection.
	private static func configureUpgrade(channel: Channel,
	                                     finder: any RouteFinder,
	                                     isTLS: Bool,
	                                     idleTimeout: TimeAmount?) throws -> EventLoopFuture<HTTPOrWebSocket> {
		// Shared between shouldUpgrade (writes) and upgradePipelineHandler (reads) for this one
		// connection — both upgrader closures run sequentially on this channel's event loop.
		let resolved = NIOLockedValueBox<(WebSocketHandler, [WebSocketOption])?>(nil)

		let upgrader = NIOTypedWebSocketServerUpgrader<HTTPOrWebSocket>(
			shouldUpgrade: { channel, head in
				// Run the route to see if this path is a WebSocket endpoint. The upgrader itself
				// validates Sec-WebSocket-Key/Version and computes Sec-WebSocket-Accept.
				let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
				let request = NIOAsyncHTTPRequest(head: head, body: [], channel: channel, isTLS: isTLS)
				Task {
					if let ws = await Server.resolveWebSocket(request, finder: finder) {
						resolved.withLockedValue { $0 = ws }
						promise.succeed(HTTPHeaders())
					} else {
						promise.succeed(nil)
					}
				}
				return promise.futureResult
			},
			upgradePipelineHandler: { channel, _ in
				channel.eventLoop.makeCompletedFuture {
					let wsChannel = try WebSocketConnectionChannel(wrappingChannelSynchronously: channel)
					let noop: WebSocketHandler = { _ in }
					let (handler, options) = resolved.withLockedValue { $0 } ?? (noop, [])
					return HTTPOrWebSocket.websocket(wsChannel, handler, options)
				}
			}
		)

		let configuration = NIOUpgradableHTTPServerPipelineConfiguration(
			upgradeConfiguration: .init(
				upgraders: [upgrader],
				notUpgradingCompletionHandler: { channel in
					channel.eventLoop.makeCompletedFuture {
						// Idle timeout applies to plain HTTP only; WebSocket connections are
						// long-lived and manage their own liveness.
						if let idleTimeout = idleTimeout {
							try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: idleTimeout))
							try channel.pipeline.syncOperations.addHandler(IdleTimeoutHandler())
						}
						return HTTPOrWebSocket.http(try HTTPConnectionChannel(wrappingChannelSynchronously: channel))
					}
				}
			)
		)
		let future = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(configuration: configuration)
		// A refused WebSocket handshake (e.g. an upgrade request to a non-WebSocket path) makes the
		// upgrader fire `unsupportedWebSocketTarget` down the pipeline. NIO then tries to fall back
		// to plain HTTP, but the buffered handshake request is not delivered to the async channel,
		// so the connection would hang. Close it promptly instead — a clean rejection.
		try channel.pipeline.syncOperations.addHandler(WebSocketUpgradeRefusalCloser())
		return future
	}

	/// Resolves a request against the routes and, if it lands on a `webSocket(...)` route,
	/// returns that route's handler + options. Returns nil for any non-WebSocket route.
	private static func resolveWebSocket(_ request: NIOAsyncHTTPRequest,
	                                     finder: any RouteFinder) async -> (WebSocketHandler, [WebSocketOption])? {
		guard let fnc = finder[request.method, request.path] else { return nil }
		let ctx = RouteContext(request: request, uri: request.path)
		do {
			let (_, output) = try await fnc(ctx, request)
			guard let wsOutput = output as? WebSocketUpgradeHTTPOutput else { return nil }
			return (wsOutput.handler, wsOutput.options)
		} catch {
			return nil
		}
	}

	/// Accept loop for one server channel: each accepted connection is handled in its own child
	/// task so slow clients never block accepts. Returns when the channel closes or on cancellation.
	private static func runAcceptLoop(_ serverChannel: HTTPServerChannel,
	                                  finder: any RouteFinder,
	                                  isTLS: Bool) async {
		do {
			try await withThrowingDiscardingTaskGroup { connections in
				try await serverChannel.executeThenClose { inbound in
					for try await upgradeResult in inbound {
						connections.addTask {
							await Server.handleConnection(upgradeResult, finder: finder, isTLS: isTLS)
						}
					}
				}
			}
		} catch {
			// Server channel closed (cancellation / shutdown) or the accept loop failed.
		}
	}

	/// Awaits one connection's upgrade outcome and dispatches it to the right driver.
	private static func handleConnection(_ upgradeResult: EventLoopFuture<HTTPOrWebSocket>,
	                                     finder: any RouteFinder,
	                                     isTLS: Bool) async {
		do {
			switch try await upgradeResult.get() {
			case .http(let channel):
				await NIOAsyncHTTPServer.handleConnection(channel, finder: finder, isTLS: isTLS)
			case .websocket(let channel, let handler, let options):
				await WebSocketRunner.run(channel, handler: handler, options: options)
			}
		} catch {
			// Upgrade negotiation failed or the connection errored before producing a result.
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

/// Closes a connection whose WebSocket upgrade was refused. The typed upgrader fires a
/// `NIOWebSocketUpgradeError` down the pipeline and then attempts an HTTP fall-back that does not
/// deliver the buffered handshake request to the async channel — so we close rather than hang.
private final class WebSocketUpgradeRefusalCloser: ChannelInboundHandler {
	typealias InboundIn = NIOAny
	func errorCaught(context: ChannelHandlerContext, error: Error) {
		if error is NIOWebSocketUpgradeError {
			context.close(promise: nil)
		} else {
			context.fireErrorCaught(error)
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
