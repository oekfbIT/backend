//
//  File.swift
//  
//
//  Created by Alon Yakoby on 19.05.24.
//

import Foundation
import Vapor
import Fluent

struct TeamRegistrationRequest: Content, Codable, LosslessStringConvertible {
    
    let primaryContact: ContactPerson
    let secondaryContact: ContactPerson
    let teamName: String
    let verein: String?
    let bundesland: Bundesland
    let type: ClubType
    let acceptedAGB: Bool
    let referCode: String
    let initialPassword: String

    // Custom initializer
    init(
        primaryContact: ContactPerson,
        secondaryContact: ContactPerson,
        teamName: String,
        verein: String?,
        bundesland: Bundesland,
        type: ClubType,
        acceptedAGB: Bool,
        referCode: String,
        initialPassword: String
    ) {
        self.primaryContact = primaryContact
        self.secondaryContact = secondaryContact
        self.teamName = teamName
        self.verein = verein
        self.bundesland = bundesland
        self.type = type
        self.acceptedAGB = acceptedAGB
        self.referCode = referCode
        self.initialPassword = initialPassword
    }
    
    // Implementing LosslessStringConvertible
    init?(_ description: String) {
        guard let data = description.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TeamRegistrationRequest.self, from: data) else {
            return nil
        }
        self = decoded
    }

    var description: String {
        guard let data = try? JSONEncoder().encode(self),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }
}

struct UpdatePaymentRequest: Content {
    var paidAmount: Double
}

