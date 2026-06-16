//
//  RouteCRUD.swift
//  PerfectNIO
//
//  Created by Kyle Jessup on 2018-10-28.
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
import PerfectCRUD
import NIO
import PerfectNIO

public typealias DCP = DatabaseConfigurationProtocol

public extension Routes {
    func db<C: DCP & Sendable, NewOut>(
        _ provide: @autoclosure @escaping @Sendable () throws -> Database<C>,
        _ call: @Sendable @escaping (OutType, Database<C>) async throws -> NewOut
    ) -> Routes<InType, NewOut> {
        map { input in
            let db = try provide()
            return try await call(input, db)
        }
    }

    func table<C: DCP & Sendable, T: Codable & Sendable, NewOut>(
        _ provide: @autoclosure @escaping @Sendable () throws -> Database<C>,
        _ type: T.Type,
        _ call: @Sendable @escaping (OutType, Table<T, Database<C>>) async throws -> NewOut
    ) -> Routes<InType, NewOut> {
        map { input in
            let table = try provide().table(type)
            return try await call(input, table)
        }
    }
}
