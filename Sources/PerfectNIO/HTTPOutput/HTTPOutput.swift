//
//  HTTPOutput.swift
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

import Foundation
import NIOHTTP1
import NIO

/// The response output for the client.
open class HTTPOutput: @unchecked Sendable {
	public init() {}

	/// Optional HTTP head for this output.
	open func head(request: HTTPRequestInfo) -> HTTPHead? { nil }

	/// Produce the next chunk of body data. Return nil when the body is complete.
	/// Subclasses override this. The base-class bridge forwards calls to body(promise:allocator:)
	/// for backward compatibility during the Phase 3 → Phase 4 transition.
	open func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? { nil }

	/// Called when the response has been fully written or on error.
	/// Override to perform cleanup (e.g. closing file handles).
	open func closed() {}

	// Bridge: forwards NIOHTTPHandler's promise-pull into nextChunk().
	// Kept open so WebSocketUpgradeHTTPOutput can still override it (Phase 6 will remove the need).
	// Subclasses should override nextChunk() instead.
	open func body(promise: EventLoopPromise<IOData?>, allocator: ByteBufferAllocator) {
		Task {
			do {
				if let buf = try await self.nextChunk(allocator: allocator) {
					promise.succeed(.byteBuffer(buf))
				} else {
					promise.succeed(nil)
				}
			} catch {
				promise.fail(error)
			}
		}
	}
}
