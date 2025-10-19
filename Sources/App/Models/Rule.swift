//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  
import Vapor
import Fluent


enum RuleType: String, Codable {
    case guide
    case rule
}

final class Rule: Model {
    
    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var title: FieldKey { "title" }
        static var content: FieldKey { "content" }
        static var type: FieldKey { "type" }
    }
    
    static let schema = "rules"
    
    @ID(custom: FieldKeys.id)
    var id: UUID?
    
    @Field(key: FieldKeys.title)
    var title: String
    
    @Field(key: FieldKeys.content)
    var content: String
    
    init() {}
    
    init(id: UUID? = nil, title: String, content: String) {
        self.id = id
        self.title = title
        self.content = content
    }
}

extension RuleMigration: Migration {
    
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Token.schema)
        .field(Rule.FieldKeys.id, .uuid, .identifier(auto: true))
        .field(Rule.FieldKeys.title, .datetime, .required)
        .field(Rule.FieldKeys.content, .datetime)
        .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Rule.schema).delete()
    }
}

