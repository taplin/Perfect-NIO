//
//  NIOHTTPHandler.swift
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

import NIO
import NIOHTTP1

// @unchecked because its mutable state is event-loop-bound; accesses from the
// async route Task are either routed back to the event loop or are reads of
// properties that are set once and never change (channel, isTLS).
final class NIOHTTPHandler: ChannelInboundHandler, HTTPRequest, @unchecked Sendable {
	public typealias InboundIn = HTTPServerRequestPart
	public typealias OutboundOut = HTTPServerResponsePart
	enum State {
		case none, head, body, end
	}
	var method: HTTPMethod { head?.method ?? .GET }
	var uri: String { head?.uri ?? "" }
	var headers: HTTPHeaders { head?.headers ?? .init() }
	var uriVariables: [String: String] = [:]
	var path: String = ""
	var searchArgs: QueryDecoder?
	var contentType: String? = nil
	var contentLength = 0
	var contentRead = 0
	var contentConsumed = 0 {
		didSet {
			assert(contentConsumed <= contentRead && contentConsumed <= contentLength)
		}
	}
	var localAddress: SocketAddress? { channel?.localAddress }
	var remoteAddress: SocketAddress? { channel?.remoteAddress }

	let finder: any RouteFinder
	var head: HTTPRequestHead?
	var channel: Channel?
	var pendingBytes: [ByteBuffer] = []
	var pendingPromise: EventLoopPromise<[ByteBuffer]>?
	var readState = State.none
	var writeState = State.none
	var forceKeepAlive: Bool? = nil
	var upgraded = false
	let isTLS: Bool

	init(finder: any RouteFinder, isTLS: Bool) {
		self.finder = finder
		self.isTLS = isTLS
	}

	func runRequest() {
		guard let requestHead = self.head, let channel = self.channel else { return }
		let requestInfo = HTTPRequestInfo(head: requestHead, options: isTLS ? .isTLS : [])
		guard let fnc = finder[requestHead.method, path] else {
			let error = ErrorOutput(status: .notFound, description: "No route for URI.")
			let head = HTTPHead(headers: HTTPHeaders()).merged(with: error.head(request: requestInfo))
			return write(head: head, body: error)
		}
		let ctx = RouteContext(request: self, uri: path)
		Task {
			do {
				let (finalCtx, body) = try await fnc(ctx, self)
				let head = finalCtx.responseHead.merged(with: body.head(request: requestInfo))
				channel.eventLoop.execute {
					self.write(head: head, body: body)
				}
			} catch {
				let body: HTTPOutput
				switch error {
				case let err as TerminationType:
					switch err {
					case .error(let e):
						body = e
					case .criteriaFailed(let status):
						body = BytesOutput(head: HTTPHead(status: status, headers: ctx.responseHeaders), body: [])
					case .internalError:
						body = ErrorOutput(status: .internalServerError, description: "Internal server error.")
					}
				case let err as ErrorOutput:
					body = err
				default:
					body = ErrorOutput(status: .internalServerError, description: "Internal server error: \(error)")
				}
				let head = ctx.responseHead.merged(with: body.head(request: requestInfo))
				channel.eventLoop.execute {
					self.write(head: head, body: body)
				}
			}
		}
	}

	func channelActive(context ctx: ChannelHandlerContext) {
		channel = ctx.channel
	}
	func channelInactive(context ctx: ChannelHandlerContext) {}
	func channelRead(context ctx: ChannelHandlerContext, data: NIOAny) {
		let reqPart = unwrapInboundIn(data)
		switch reqPart {
		case .head(let head): http(head: head, ctx: ctx)
		case .body(let body): http(body: body, ctx: ctx)
		case .end(let headers): http(end: headers, ctx: ctx)
		}
	}
	func errorCaught(context ctx: ChannelHandlerContext, error: Error) {
		ctx.close(promise: nil)
	}
	func http(head: HTTPRequestHead, ctx: ChannelHandlerContext) {
		assert(contentLength == 0)
		readState = .head
		self.head = head
		let (path, args) = head.uri.splitQuery
		self.path = path
		if let args = args {
			searchArgs = QueryDecoder(Array(args.utf8))
		}
		contentType = head.headers["content-type"].first
		contentLength = Int(head.headers["content-length"].first ?? "0") ?? 0
	}
	func http(body: ByteBuffer, ctx: ChannelHandlerContext) {
		let onlyHead = readState == .head
		readState = .body
		let readable = body.readableBytes
		if contentRead + readable > contentLength {
			let diff = contentLength - contentRead
			if diff > 0, let s = body.getSlice(at: 0, length: diff) {
				pendingBytes.append(s)
			}
			contentRead = contentLength
		} else {
			contentRead += readable
			pendingBytes.append(body)
		}
		if contentRead == contentLength {
			readState = .end
		}
		if let p = pendingPromise {
			pendingPromise = nil
			p.succeed(consumeContent())
		}
		if onlyHead {
			runRequest()
		}
	}
	func http(end: HTTPHeaders?, ctx: ChannelHandlerContext) {
		if case .head = readState {
			runRequest()
		}
	}
	func reset() {
		writeState = .none
		readState = .none
		head = nil
		contentLength = 0
		contentConsumed = 0
		contentRead = 0
		forceKeepAlive = nil
		uriVariables = [:]
		path = ""
		searchArgs = nil
		contentType = nil
	}
	func userInboundEventTriggered(context ctx: ChannelHandlerContext, event: Any) {
		switch event {
		case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
			switch readState {
			case .none, .body:
				ctx.close(promise: nil)
			case .end, .head:
				forceKeepAlive = false
			}
		default:
			ctx.fireUserInboundEventTriggered(event)
		}
	}
	func channelReadComplete(context ctx: ChannelHandlerContext) {}
}

// MARK: - Reading (Future-based internals, bridged to async via protocol)

extension NIOHTTPHandler {
	func consumeContent() -> [ByteBuffer] {
		let cpy = pendingBytes
		pendingBytes = []
		let sum = cpy.reduce(0) { $0 + $1.readableBytes }
		contentConsumed += sum
		return cpy
	}

	// HTTPRequest async conformance — bridges to the event-loop Future implementations.
	func readSomeContent() async throws -> [ByteBuffer] {
		guard let ch = channel else { return [] }
		return try await ch.eventLoop.submit {
			() -> EventLoopFuture<[ByteBuffer]> in
			self.readSomeContentFuture()
		}.flatMap { $0 }.get()
	}

	func readContent() async throws -> HTTPRequestContentType {
		guard let ch = channel else { return .none }
		return try await ch.eventLoop.submit {
			() -> EventLoopFuture<HTTPRequestContentType> in
			self.readContentFuture()
		}.flatMap { $0 }.get()
	}

	private func readSomeContentFuture() -> EventLoopFuture<[ByteBuffer]> {
		precondition(nil != self.channel)
		let channel = self.channel!
		let promise: EventLoopPromise<[ByteBuffer]> = channel.eventLoop.makePromise()
		guard contentConsumed < contentLength else {
			promise.succeed([])
			return promise.futureResult
		}
		let content = consumeContent()
		if !content.isEmpty {
			promise.succeed(content)
		} else {
			pendingPromise = promise
		}
		return promise.futureResult
	}

	private func readContentFuture() -> EventLoopFuture<HTTPRequestContentType> {
		if contentLength == 0 || contentConsumed == contentLength {
			return channel!.eventLoop.makeSucceededFuture(.none)
		}
		let ct = contentType ?? "application/octet-stream"
		if ct.hasPrefix("multipart/form-data") {
			let p: EventLoopPromise<HTTPRequestContentType> = channel!.eventLoop.makePromise()
			readContentMulti(multi: MimeReader(ct), p)
			return p.futureResult
		} else {
			let p: EventLoopPromise<[UInt8]> = channel!.eventLoop.makePromise()
			readContentBytes(p)
			if ct.hasPrefix("application/x-www-form-urlencoded") {
				return p.futureResult.map { .urlForm(QueryDecoder($0)) }
			} else {
				return p.futureResult.map { .other($0) }
			}
		}
	}

	private func readContentMulti(multi: MimeReader, _ promise: EventLoopPromise<HTTPRequestContentType>) {
		if contentConsumed < contentRead {
			consumeContent().forEach {
				multi.addToBuffer(bytes: $0.getBytes(at: 0, length: $0.readableBytes) ?? [])
			}
		}
		if contentConsumed == contentLength {
			return promise.succeed(.multiPartForm(multi))
		}
		readSomeContentFuture().whenSuccess { buffers in
			buffers.forEach { multi.addToBuffer(bytes: $0.getBytes(at: 0, length: $0.readableBytes) ?? []) }
			self.readContentMulti(multi: multi, promise)
		}
	}

	private func readContentBytes(_ promise: EventLoopPromise<[UInt8]>) {
		if contentRead == contentLength {
			var a: [UInt8] = []
			consumeContent().forEach { a.append(contentsOf: $0.getBytes(at: 0, length: $0.readableBytes) ?? []) }
			return promise.succeed(a)
		}
		readContentBytesAccum(accum: [], promise)
	}

	private func readContentBytesAccum(accum: [UInt8], _ promise: EventLoopPromise<[UInt8]>) {
		readSomeContentFuture().whenSuccess { buffers in
			var a: [UInt8]
			if buffers.count == 1 && accum.isEmpty {
				a = buffers.first!.getBytes(at: 0, length: buffers.first!.readableBytes) ?? []
			} else {
				a = accum
				buffers.forEach { a.append(contentsOf: $0.getBytes(at: 0, length: $0.readableBytes) ?? []) }
			}
			if self.contentConsumed == self.contentLength {
				promise.succeed(a)
			} else {
				self.readContentBytesAccum(accum: a, promise)
			}
		}
	}
}

// MARK: - Writing

extension NIOHTTPHandler {
	func write(head: HTTPHead, body: HTTPOutput) {
		writeHead(head)
		writeBody(body)
	}
	private func writeHead(_ output: HTTPHead) {
		guard let head = head else { return }
		writeState = .head
		var h = HTTPResponseHead(version: head.version,
		                         status: output.status ?? .ok,
		                         headers: output.headers)
		if !self.headers.contains(name: "keep-alive") && !self.headers.contains(name: "close") {
			switch (head.isKeepAlive, head.version.major, head.version.minor) {
			case (true, 1, 0):
				h.headers.add(name: "Connection", value: "keep-alive")
			case (false, 1, let n) where n >= 1:
				h.headers.add(name: "Connection", value: "close")
			default:
				()
			}
		}
		channel?.write(wrapOutboundOut(.head(h)), promise: nil)
	}
	private func writeBody(_ body: HTTPOutput) {
		guard let channel = self.channel, writeState != .end else { return }
		let promiseBytes = channel.eventLoop.makePromise(of: IOData?.self)
		promiseBytes.futureResult.whenSuccess {
			let writeDonePromise: EventLoopPromise<Void> = channel.eventLoop.makePromise()
			if let bytes = $0 {
				writeDonePromise.futureResult.whenSuccess {
					_ = channel.eventLoop.submit { self.writeBody(body) }
				}
				if bytes.readableBytes > 0 {
					channel.writeAndFlush(self.wrapOutboundOut(.body(bytes)), promise: writeDonePromise)
				} else {
					writeDonePromise.succeed(())
				}
			} else {
				let keepAlive = self.forceKeepAlive ?? self.head?.isKeepAlive ?? false
				self.reset()
				if !self.upgraded {
					body.closed()
					writeDonePromise.futureResult.whenComplete { _ in
						if !keepAlive { channel.close(promise: nil) }
					}
					channel.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writeDonePromise)
				} else {
					channel.flush()
				}
			}
			writeDonePromise.futureResult.whenFailure { _ in
				channel.close(promise: nil)
				body.closed()
			}
		}
		promiseBytes.futureResult.whenFailure { _ in
			channel.close(promise: nil)
			body.closed()
		}
		body.body(promise: promiseBytes, allocator: channel.allocator)
	}
}
