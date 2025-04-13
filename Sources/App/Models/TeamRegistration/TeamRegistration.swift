//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//

import Foundation
import Fluent
import Vapor

enum TeamRegistrationStatus: String, Codable {
    case draft, verified, rejected, approved, paid, teamCustomization, completed
}

final class TeamRegistration: Model, Content, Mergeable {
    static let schema = "registrations"

    @ID(custom: "id") var id: UUID?
    @OptionalField(key: FieldKeys.primary) var primary: ContactPerson?
    @OptionalField(key: FieldKeys.secondary) var secondary: ContactPerson?
    @OptionalField(key: FieldKeys.verein) var verein: String?
    @Field(key: FieldKeys.teamName) var teamName: String
    @Field(key: FieldKeys.status) var status: TeamRegistrationStatus
    @Field(key: FieldKeys.bundesland) var bundesland: Bundesland
    @Field(key: FieldKeys.initialPassword) var initialPassword: String?
    @OptionalField(key: FieldKeys.refereerLink) var refereerLink: String?
    @OptionalField(key: FieldKeys.assignedLeague) var assignedLeague: UUID?
    @OptionalField(key: FieldKeys.customerSignedContract) var customerSignedContract: String? // URL
    @OptionalField(key: FieldKeys.adminSignedContract) var adminSignedContract: String? // URL
    @OptionalField(key: FieldKeys.teamLogo) var teamLogo: String? // URL
    @OptionalField(key: FieldKeys.paidAmount) var paidAmount: Double?
    @OptionalField(key: FieldKeys.user) var user: UUID?
    @OptionalField(key: FieldKeys.team) var team: UUID?
    @OptionalField(key: FieldKeys.isWelcomeEmailSent) var isWelcomeEmailSent: Bool?
    @OptionalField(key: FieldKeys.isLoginDataSent) var isLoginDataSent: Bool?
    @OptionalField(key: FieldKeys.dateCreated) var dateCreated: Date?

    @OptionalField(key: FieldKeys.kaution) var kaution: Double?
    
    
    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var primary: FieldKey { "primary" }
        static var secondary: FieldKey { "secondary" }
        static var verein: FieldKey { "verein" }
        static var teamName: FieldKey { "teamName" }
        static var status: FieldKey { "status" }
        static var bundesland: FieldKey { "bundesland" }
        static var initialPassword: FieldKey { "initialPassword" }
        static var refereerLink: FieldKey { "refereerLink" }
        static var customerSignedContract: FieldKey { "customerSignedContract" }
        static var adminSignedContract: FieldKey { "adminSignedContract" }
        static var assignedLeague: FieldKey { "assignedLeague" }
        static var paidAmount: FieldKey { "paidAmount" }
        static var user: FieldKey { "user" }
        static var team: FieldKey { "team" }
        static var teamLogo: FieldKey { "teamLogo" }
        static var isWelcomeEmailSent: FieldKey { "isWelcomeEmailSent" }
        static var isLoginDataSent: FieldKey { "isLoginDataSent" }
        static var dateCreated: FieldKey { "dateCreated" }
        static var kaution: FieldKey { "kaution" }
    }
    
    init() {}
    
    init(id: UUID? = nil, primary: ContactPerson? = nil, secondary: ContactPerson? = nil, verein: String? = nil, teamName: String, status: TeamRegistrationStatus, bundesland: Bundesland, initialPassword: String? , refereerLink: String? = nil, assignedLeague: UUID? = nil, customerSignedContract: String? = nil, adminSignedContract: String? = nil, teamLogo: String?, paidAmount: Double? = nil, user: UUID? = nil, team: UUID? = nil, isWelcomeEmailSent: Bool? = nil, isLoginDataSent: Bool? = nil, dateCreated: Date? = Date.viennaNow, kaution: Double? = nil) {
        self.id = id
        self.primary = primary
        self.secondary = secondary
        self.verein = verein
        self.teamName = teamName
        self.status = status 
        self.bundesland = bundesland
        self.initialPassword = initialPassword
        self.refereerLink = refereerLink
        self.assignedLeague = assignedLeague
        self.customerSignedContract = customerSignedContract
        self.adminSignedContract = adminSignedContract
        self.teamLogo = teamLogo
        self.paidAmount = paidAmount
        self.user = user
        self.team = team
        self.isWelcomeEmailSent = isWelcomeEmailSent
        self.isLoginDataSent = isLoginDataSent
        self.dateCreated = dateCreated
        self.kaution = kaution
    }
}

// Team Migration
extension TeamRegistrationMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(TeamRegistration.schema)
            .id()
            .field(TeamRegistration.FieldKeys.primary, .json)
            .field(TeamRegistration.FieldKeys.secondary, .json)
            .field(TeamRegistration.FieldKeys.verein, .string)
            .field(TeamRegistration.FieldKeys.teamName, .string, .required)
            .field(TeamRegistration.FieldKeys.bundesland, .string)
            .field(TeamRegistration.FieldKeys.initialPassword, .string, .required)
            .field(TeamRegistration.FieldKeys.refereerLink, .string)
            .field(TeamRegistration.FieldKeys.customerSignedContract, .string)
            .field(TeamRegistration.FieldKeys.adminSignedContract, .string)
            .field(TeamRegistration.FieldKeys.teamLogo, .string)
            .field(TeamRegistration.FieldKeys.assignedLeague, .uuid)
            .field(TeamRegistration.FieldKeys.paidAmount, .double)
            .field(TeamRegistration.FieldKeys.user, .uuid)
            .field(TeamRegistration.FieldKeys.team, .uuid)
            .field(TeamRegistration.FieldKeys.isWelcomeEmailSent, .bool)
            .field(TeamRegistration.FieldKeys.isLoginDataSent, .bool)
            .field(TeamRegistration.FieldKeys.dateCreated, .date)
            .field(TeamRegistration.FieldKeys.kaution, .double)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(TeamRegistration.schema).delete()
    }
}

extension String {
    static func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map{ _ in letters.randomElement()! })
    }

    static func randomNum(length: Int) -> String {
        let letters = "0123456789"
        return String((0..<length).map{ _ in letters.randomElement()! })
    }

}


// Example usage:
//let password = generateRandomPassword()
//print("Generated password: \(password)")

extension TeamRegistration {
    func merge(from other: TeamRegistration) -> TeamRegistration {
        var merged = self
        merged.id = other.id
        merged.primary = other.primary
        merged.secondary = other.secondary
        merged.initialPassword = initialPassword
        merged.verein = other.verein
        merged.teamName = other.teamName
        merged.bundesland = other.bundesland
        merged.refereerLink = other.refereerLink
        merged.customerSignedContract = other.customerSignedContract
        merged.adminSignedContract = other.adminSignedContract
        merged.teamLogo = other.teamLogo
        merged.assignedLeague = other.assignedLeague
        merged.paidAmount = other.paidAmount
        merged.user = other.user
        merged.team = other.team
        merged.isWelcomeEmailSent = other.isWelcomeEmailSent
        merged.isLoginDataSent = other.isLoginDataSent
        merged.dateCreated = other.dateCreated
        merged.kaution = other.kaution
        return merged
    }
}
