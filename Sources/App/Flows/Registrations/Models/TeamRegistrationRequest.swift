//
//  File.swift
//  
//
//  Created by Alon Yakoby on 19.05.24.
//

import Foundation

struct TeamRegistrationRequest: Codable {
    let primaryContact: ContactPerson
    let secondaryContact: ContactPerson
    let company, verein: String?
    let bundesland: Bundesland
    let type: ClubType
    let acceptedAGB: Bool
    let initialContact: InitialContact
    let referCode: String
}
