//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  
import Vapor
import Fluent

enum SessionSource: Int, Content {
    case signup = 0
    case login = 1 
}


final class Token: Model {
    
    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var user: FieldKey { "user_id" }
        static var value: FieldKey { "value" }
        static var source: FieldKey { "source" }
        static var expiresAt: FieldKey { "expires_at" }
        static var updatedAt: FieldKey { "created_at" }
    }
    
    static let schema = "token"
    
    @ID(custom: FieldKeys.id)
    var id: UUID?
    
    @Parent(key: FieldKeys.user)
    var user: User
    
    @Field(key: FieldKeys.value)
    var value: String
    
    @Field(key: FieldKeys.source)
    var source: SessionSource
    
    @Field(key: FieldKeys.expiresAt)
    var expiresAt: Date?
    
    @Timestamp(key: FieldKeys.updatedAt, on: .create)
    var createdAt: Date?
    
    init() {}
    
    init(id: UUID? = nil, userId: User.IDValue, token: String,
         source: SessionSource, expiresAt: Date?) {
        self.id = id
        self.$user.id = userId
        self.value = token
        self.source = source
        self.expiresAt = expiresAt
    }
}

extension Token: ModelTokenAuthenticatable {
    static let valueKey = \Token.$value
    static let userKey = \Token.$user
    
    var isValid: Bool {
        guard let expiryDate = expiresAt else {
            return true
        }
        
        return expiryDate > Date.viennaNow
    }
}

extension TokenMigration: Migration {
    
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Token.schema)
        .field(Token.FieldKeys.id, .uuid, .identifier(auto: true))
        .field(Token.FieldKeys.user, .uuid, .references("users", "id"))
        .field(Token.FieldKeys.value, .string, .required)
        .unique(on: Token.FieldKeys.value)
        .field(Token.FieldKeys.source, .int, .required)
        .field(Token.FieldKeys.updatedAt, .datetime, .required)
        .field(Token.FieldKeys.expiresAt, .datetime)
        .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Token.schema).delete()
    }
}

