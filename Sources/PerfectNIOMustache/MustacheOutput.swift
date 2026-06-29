//
//  MustacheOutput.swift
//  PerfectNIOMustache
//
//  Moved to optional target — import PerfectNIOMustache to use.
//

import Foundation
import PerfectMustache
import NIOHTTP1
import NIO
import PerfectNIO

public class MustacheOutput: HTTPOutput, @unchecked Sendable {
	private let responseHead: HTTPHead?
	private var bodyBytes: [UInt8]?
	public init(templatePath: String,
				inputs: [String: Any],
				contentType: String) throws {
		let context = MustacheEvaluationContext(templatePath: templatePath, map: inputs)
		let collector = MustacheEvaluationOutputCollector()
		let result = try context.formulateResponse(withCollector: collector)
		let body = Array(result.utf8)
		bodyBytes = body
		responseHead = HTTPHead(headers: HTTPHeaders([
			("Content-Type", contentType),
			("Content-Length", "\(body.count)"),
		]))
	}
	public override func head(request: HTTPRequestInfo) -> HTTPHead? {
		return responseHead
	}
	public override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
		guard let b = bodyBytes else { return nil }
		bodyBytes = nil
		var buf = allocator.buffer(capacity: b.count)
		buf.writeBytes(b)
		return buf
	}
}
