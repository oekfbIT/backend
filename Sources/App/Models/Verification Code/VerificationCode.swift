//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 28.01.26.
//

import Foundation
import Foundation
import Fluent
import Vapor

enum VerificationCodeStatus: String, Codable {
    case unsent, sent, verified
}


final class VerificationCode: Model, Content, Codable {
    static let schema = "verifications"

    @ID(custom: FieldKeys.id) var id: UUID?
    @OptionalField(key: FieldKeys.code) var code: String?
    @OptionalField(key: FieldKeys.userid) var userid: UUID?
    @OptionalField(key: FieldKeys.email) var email: String?
    @OptionalField(key: FieldKeys.status) var status: VerificationCodeStatus?
    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var code: FieldKey { "code" }
        static var userid: FieldKey { "userid" }
        static var email: FieldKey { "email" }
        static var status: FieldKey { "status" }
        static var created: FieldKey { "created" }
    }

    init() {}

    init(id: UUID? = nil, code: String?, userid: UUID?, email: String?, status: VerificationCodeStatus?) {
        self.id = id
        self.code = code
        self.userid = userid
        self.email = email
        self.status = status
        self.created = Date.viennaNow
    }
}

extension VerificationCode: Mergeable {
    func merge(from other: VerificationCode) -> VerificationCode {
        var merged = self
        merged.code = other.code ?? self.code
        merged.userid = other.userid ?? self.userid
        merged.email = other.email ?? self.email
        merged.status = other.status ?? self.status
        merged.created = other.created ?? self.created
        return merged
    }
}

// NewsItem Migration
extension VerificationCodeMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(VerificationCode.schema)
            .field(VerificationCode.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(VerificationCode.FieldKeys.code, .string)
            .field(VerificationCode.FieldKeys.userid, .uuid)
            .field(VerificationCode.FieldKeys.email, .string)
            .field(VerificationCode.FieldKeys.status, .json)
            .field(VerificationCode.FieldKeys.created, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(VerificationCode.schema).delete()
    }
}
