//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  
import Foundation
import Fluent
import Vapor

final class User: Model, Content, Codable {
    static let schema = "user"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.userID) var userID: String
    @Field(key: FieldKeys.type) var type: UserType
    @Field(key: FieldKeys.firstName) var firstName: String
    @Field(key: FieldKeys.lastName) var lastName: String
    @OptionalField(key: FieldKeys.verified) var verified: Bool?
    @OptionalField(key: FieldKeys.tel) var tel: String?
    @Field(key: FieldKeys.email) var email: String
    @Field(key: FieldKeys.passwordHash) var passwordHash: String
    @Children(for: \.$user) var teams: [Team]
    @Children(for: \.$user) var referees: [Referee]

    
    struct Public: Content, Codable {
        let id: UUID
        let userID: String
        let email: String
        let tel: String?
        let verified: Bool?
        let type: UserType
        let passwordHash: String
        let first: String
        let last: String
    }

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var userID: FieldKey { "userID" }
        static var type: FieldKey { "type" }
        static var firstName: FieldKey { "firstName" }
        static var lastName: FieldKey { "lastName" }
        static var email: FieldKey { "email" }
        static var tel: FieldKey { "tel" }
        static var verified: FieldKey { "verified" }
        static var passwordHash: FieldKey { "passwordHash" }
    }

    init() {}
    
    init(id: UUID? = nil, userID: String, type: UserType, firstName: String, lastName: String, verified: Bool? = false,  email: String, tel: String? = nil, passwordHash: String) {
        self.id = id
        self.userID = userID
        self.type = type
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.tel = tel
        self.verified = verified
        self.passwordHash = passwordHash
    }
}

extension UserMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        return database.schema(User.schema)
            .field(User.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(User.FieldKeys.type, .string, .required)
            .field(User.FieldKeys.firstName, .string, .required)
            .field(User.FieldKeys.lastName, .string, .required)
            .field(User.FieldKeys.email, .string, .required)
            .field(User.FieldKeys.tel, .string)
            .field(User.FieldKeys.verified, .bool)
            .field(User.FieldKeys.passwordHash, .string, .required)
            .unique(on: User.FieldKeys.email)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        return database.schema(User.schema).delete()
    }
}

enum UserType: String, Codable {
    case admin
    case referee
    case team
    case manager
    case player

    var position: String {
        switch self {
            case .admin: return "Admin"
            case .referee: return "Schiedrichter"
            case .team: return "Mannschaft"
            case .manager: return "Manager"
            case .player: return "Spieler"
        }
    }
}

extension User {
    func toAppUser() throws -> AppModels.AppUser {
        AppModels.AppUser(
            id: try requireID(),
            type: type,
            firstname: firstName,
            lastname: lastName,
            email: email
        )
    }
}

extension User: Authenticatable {
    static func create(from userSignup: UserSignup) throws -> User {
        User(userID:userSignup.id,
             type: userSignup.type,
             firstName: userSignup.firstName,
             lastName: userSignup.lastName,
             email: userSignup.email,
             passwordHash: try Bcrypt.hash(userSignup.password))
    }
    
    func createToken(source: SessionSource) throws -> Token {
        let calendar = Calendar(identifier: .gregorian)
        let expiryDate = calendar.date(byAdding: .year, value: 1, to: Date.viennaNow)
        return try Token(userId: requireID(),
                         token: [UInt8].random(count: 16).base64,
                         source: source,
                         expiresAt: expiryDate)
    }
    
    func asPublic() throws -> Public {
        Public(id: try requireID(),
               userID: userID,
               email: email,
               tel: tel,
               verified: verified,
               type: type,
               passwordHash: passwordHash,
               first: firstName,
               last: lastName)
    }
}

extension User: ModelAuthenticatable {
    static let usernameKey = \User.$email
    static let passwordHashKey = \User.$passwordHash
    
    func verify(password: String) throws -> Bool {
        print("Input password: \(password)")
        print("Hashed password: \(self.passwordHash)")
        let result = try Bcrypt.verify(password, created: self.passwordHash)
        print("Password verification result: \(result)")
        return result
    }
}

