//
//  RouteServer.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2018-10-24.
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

import NIO
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOConcurrencyHelpers
import Foundation

/// Routes which have been bound to a port and have started listening for connections.
public protocol ListeningRoutes {
	/// Stop listening for requests
	@discardableResult
	func stop() -> ListeningRoutes
	/// Wait, perhaps forever, until the routes have stopped listening for requests.
	func wait() throws
}

/// Routes which have been bound to an address but are not yet listening for requests.
public protocol BoundRoutes {
	/// The address the server is bound to.
	var address: SocketAddress { get }
	/// Start listening
	func listen() throws -> ListeningRoutes
}

typealias HTTPConnectionChannel = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
typealias HTTPServerChannel = NIOAsyncChannel<HTTPConnectionChannel, Never>

// Phase 4 keeps the synchronous `bind().listen()` surface (the smoke tests and existing
// callers depend on it). The NIOAsyncChannel server bootstrap is async-only, so binding is
// bridged to sync here. Phase 5 replaces this with a natively-async `Server.run(routes:)`.
final class NIOBoundRoutes: BoundRoutes, @unchecked Sendable {
	public let address: SocketAddress
	private let group: MultiThreadedEventLoopGroup
	private let serverChannel: HTTPServerChannel
	private let finder: any RouteFinder
	private let isTLS: Bool

	init(registry: Routes<HTTPRequest, HTTPOutput>,
		 address: SocketAddress,
		 reusePort: Bool,
		 tls: TLSConfiguration?) throws {
		let finder = try RouteFinderDual(registry)
		self.finder = finder
		self.address = address
		self.isTLS = tls != nil

		let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
		self.group = group

		let sslContext: NIOSSLContext? = try tls.map { try NIOSSLContext(configuration: $0) }

		// ServerBootstrap is not Sendable, so build and bind it entirely inside the bridged
		// async closure — only Sendable values (group, address, reusePort, sslContext) cross in.
		self.serverChannel = try NIOBoundRoutes.runBlocking {
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
			return try await bootstrap.bind(to: address) { childChannel in
				childChannel.eventLoop.makeCompletedFuture {
					if let sslContext = sslContext {
						try childChannel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
					}
					try childChannel.pipeline.syncOperations.configureHTTPServerPipeline()
					return try HTTPConnectionChannel(wrappingChannelSynchronously: childChannel)
				}
			}
		}
	}

	public func listen() throws -> ListeningRoutes {
		return NIOListeningRoutes(serverChannel: serverChannel, group: group, finder: finder, isTLS: isTLS)
	}

	/// Runs an async operation to completion from a synchronous context.
	/// Safe here because the caller is an application/test thread, not a cooperative-pool
	/// thread, so blocking it does not starve the async runtime.
	static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
		let resultBox = NIOLockedValueBox<Result<T, Error>?>(nil)
		let semaphore = DispatchSemaphore(value: 0)
		Task {
			let r: Result<T, Error>
			do { r = .success(try await body()) }
			catch { r = .failure(error) }
			resultBox.withLockedValue { $0 = r }
			semaphore.signal()
		}
		semaphore.wait()
		return try resultBox.withLockedValue { $0! }.get()
	}
}

final class NIOListeningRoutes: ListeningRoutes, @unchecked Sendable {
	private let underlyingChannel: Channel
	private let group: MultiThreadedEventLoopGroup
	private let task: Task<Void, Never>
	private nonisolated(unsafe) static var globalInitialized: Bool = {
		var sa = sigaction()
		// !FIX! re-evaluate which of these are required
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

	init(serverChannel: HTTPServerChannel,
		 group: MultiThreadedEventLoopGroup,
		 finder: any RouteFinder,
		 isTLS: Bool) {
		_ = NIOListeningRoutes.globalInitialized
		self.underlyingChannel = serverChannel.channel
		self.group = group
		// One task per server channel runs the accept loop; each accepted connection
		// is handled in its own child task so slow clients never block the accept loop.
		self.task = Task {
			do {
				try await withThrowingDiscardingTaskGroup { taskGroup in
					try await serverChannel.executeThenClose { inbound in
						for try await connectionChannel in inbound {
							taskGroup.addTask {
								await NIOAsyncHTTPServer.handleConnection(connectionChannel, finder: finder, isTLS: isTLS)
							}
						}
					}
				}
			} catch {
				// Server channel closed (via stop()) or the accept loop failed.
			}
		}
	}

	@discardableResult
	public func stop() -> ListeningRoutes {
		underlyingChannel.close(promise: nil)
		return self
	}
	public func wait() throws {
		try underlyingChannel.closeFuture.wait()
	}
}

public extension Routes where InType == HTTPRequest, OutType == HTTPOutput {
	func bind(port: Int, tls: TLSConfiguration? = nil) throws -> BoundRoutes {
		let address = try SocketAddress(ipAddress: "0.0.0.0", port: port)
		return try bind(address: address, tls: tls)
	}
	func bind(address: SocketAddress, tls: TLSConfiguration? = nil) throws -> BoundRoutes {
		return try NIOBoundRoutes(registry: self, address: address, reusePort: false, tls: tls)
	}
	func bind(count: Int, address: SocketAddress, tls: TLSConfiguration? = nil) throws -> [BoundRoutes] {
		if count == 1 {
			return [try bind(address: address, tls: tls)]
		}
		return try (0..<count).map { _ in
			try NIOBoundRoutes(registry: self, address: address, reusePort: true, tls: tls)
		}
	}
}

extension HTTPMethod {
	static var allCases: [HTTPMethod] {
		return [
		.GET,.PUT,.ACL,.HEAD,.POST,.COPY,.LOCK,.MOVE,.BIND,.LINK,.PATCH,
		.TRACE,.MKCOL,.MERGE,.PURGE,.NOTIFY,.SEARCH,.UNLOCK,.REBIND,.UNBIND,
		.REPORT,.DELETE,.UNLINK,.CONNECT,.MSEARCH,.OPTIONS,.PROPFIND,.CHECKOUT,
		.PROPPATCH,.SUBSCRIBE,.MKCALENDAR,.MKACTIVITY,.UNSUBSCRIBE
		]
	}
	var name: String {
		switch self {
		case .GET:
			return "GET"
		case .PUT:
			return "PUT"
		case .ACL:
			return "ACL"
		case .HEAD:
			return "HEAD"
		case .POST:
			return "POST"
		case .COPY:
			return "COPY"
		case .LOCK:
			return "LOCK"
		case .MOVE:
			return "MOVE"
		case .BIND:
			return "BIND"
		case .LINK:
			return "LINK"
		case .PATCH:
			return "PATCH"
		case .TRACE:
			return "TRACE"
		case .MKCOL:
			return "MKCOL"
		case .MERGE:
			return "MERGE"
		case .PURGE:
			return "PURGE"
		case .NOTIFY:
			return "NOTIFY"
		case .SEARCH:
			return "SEARCH"
		case .UNLOCK:
			return "UNLOCK"
		case .REBIND:
			return "REBIND"
		case .UNBIND:
			return "UNBIND"
		case .REPORT:
			return "REPORT"
		case .DELETE:
			return "DELETE"
		case .UNLINK:
			return "UNLINK"
		case .CONNECT:
			return "CONNECT"
		case .MSEARCH:
			return "MSEARCH"
		case .OPTIONS:
			return "OPTIONS"
		case .PROPFIND:
			return "PROPFIND"
		case .CHECKOUT:
			return "CHECKOUT"
		case .PROPPATCH:
			return "PROPPATCH"
		case .SUBSCRIBE:
			return "SUBSCRIBE"
		case .MKCALENDAR:
			return "MKCALENDAR"
		case .MKACTIVITY:
			return "MKACTIVITY"
		case .UNSUBSCRIBE:
			return "UNSUBSCRIBE"
		case .SOURCE:
			return "SOURCE"
		case .RAW(let value):
			return value
		}
	}
}

extension HTTPMethod: Hashable {
	public func hash(into hasher: inout Hasher) {
		hasher.combine(name.hashValue)
	}
}

extension String {
	var method: HTTPMethod {
		switch self {
		case "GET":
			return .GET
		case "PUT":
			return .PUT
		case "ACL":
			return .ACL
		case "HEAD":
			return .HEAD
		case "POST":
			return .POST
		case "COPY":
			return .COPY
		case "LOCK":
			return .LOCK
		case "MOVE":
			return .MOVE
		case "BIND":
			return .BIND
		case "LINK":
			return .LINK
		case "PATCH":
			return .PATCH
		case "TRACE":
			return .TRACE
		case "MKCOL":
			return .MKCOL
		case "MERGE":
			return .MERGE
		case "PURGE":
			return .PURGE
		case "NOTIFY":
			return .NOTIFY
		case "SEARCH":
			return .SEARCH
		case "UNLOCK":
			return .UNLOCK
		case "REBIND":
			return .REBIND
		case "UNBIND":
			return .UNBIND
		case "REPORT":
			return .REPORT
		case "DELETE":
			return .DELETE
		case "UNLINK":
			return .UNLINK
		case "CONNECT":
			return .CONNECT
		case "MSEARCH":
			return .MSEARCH
		case "OPTIONS":
			return .OPTIONS
		case "PROPFIND":
			return .PROPFIND
		case "CHECKOUT":
			return .CHECKOUT
		case "PROPPATCH":
			return .PROPPATCH
		case "SUBSCRIBE":
			return .SUBSCRIBE
		case "MKCALENDAR":
			return .MKCALENDAR
		case "MKACTIVITY":
			return .MKACTIVITY
		case "UNSUBSCRIBE":
			return .UNSUBSCRIBE
		default:
			return .RAW(value: self)
		}
	}
	var splitMethod: (HTTPMethod?, String) {
		if let i = range(of: "://") {
			return (String(self[self.startIndex..<i.lowerBound]).method, String(self[i.upperBound...]))
		}
		return (nil, self)
	}
}

public extension Routes {
	var GET: Routes<InType, OutType> { method(.GET) }
	var POST: Routes { method(.POST) }
	var PUT: Routes { method(.PUT) }
	var DELETE: Routes { method(.DELETE) }
	var OPTIONS: Routes { method(.OPTIONS) }
	func method(_ method: HTTPMethod, _ methods: HTTPMethod...) -> Routes {
		let allMethods = [method] + methods
		return .init(Dictionary(routes.flatMap { key, handler in
			allMethods.map { m in (m.name + "://" + key.splitMethod.1, handler) }
		}, uniquingKeysWith: { $1 }))
	}
}
