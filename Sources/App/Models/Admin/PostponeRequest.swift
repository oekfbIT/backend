

import Foundation
import Fluent
import Vapor

final class PostponeRequest: Model, Content, Codable {
    static let schema = "postone_requests"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Parent(key: FieldKeys.match) var match: Match
    @Field(key: FieldKeys.requester) var requester: PublicTeamShort
    @Field(key: FieldKeys.requestee) var requestee: PublicTeamShort
    @OptionalField(key: FieldKeys.response) var response: Bool?
    @Field(key: FieldKeys.status) var status: Bool
    @Field(key: FieldKeys.responseDate) var responseDate: Date?
    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?

    enum FieldKeys {
        static let id: FieldKey = "id"
        static let match: FieldKey = "match"
        static let requester: FieldKey = "requester"
        static let requestee: FieldKey = "requestee"
        static let response: FieldKey = "response"
        static let responseDate: FieldKey = "responseDate"
        static let status: FieldKey = "status"
        static let created: FieldKey = "created"
    }

    init() {}

    init(id: UUID? = nil, match: Match.IDValue, requester: PublicTeamShort, requestee: PublicTeamShort, response: Bool? = nil, status: Bool, responseDate: Date?) {
        self.id = id
        self.$match.id = match
        self.requester = requester
        self.requestee = requestee
        self.response = response
        self.status = status
        self.responseDate = responseDate
        
    }
}

extension PostponeRequest: Mergeable {
    func merge(from other: PostponeRequest) -> PostponeRequest {
        var merged = self
        merged.$match.id = other.$match.id
        merged.requester = other.requester
        merged.requestee = other.requestee
        merged.response = other.response
        merged.responseDate = other.responseDate
        merged.status = other.status
        merged.created = other.created
        return merged
    }
}

// MatchEvent Migration
extension PostponeRequestMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(PostponeRequest.schema)
            .field(PostponeRequest.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(PostponeRequest.FieldKeys.match, .uuid, .required, .references(Match.schema, Match.FieldKeys.id))
            .field(PostponeRequest.FieldKeys.requester, .json)
            .field(PostponeRequest.FieldKeys.requestee, .json)
            .field(PostponeRequest.FieldKeys.response, .bool)
            .field(PostponeRequest.FieldKeys.status, .bool)
            .field(PostponeRequest.FieldKeys.responseDate, .date)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(PostponeRequest.schema).delete()
    }
}
