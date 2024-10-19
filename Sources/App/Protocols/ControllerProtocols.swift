//
//  File.swift
//  
//
//  Created by Alon Yakoby on 29.03.24.
//

import Foundation
import Vapor
import Fluent
// Controller Protocols

protocol AdminSectionProtocol {
    // MARK: AUTHENTICATION
    // MARK: FOLLOWING INCLUDED IN 'DBModelControllerRepository'
    // create, createBatch, index, getbyID, filter, getbyBatch, getByFieldValue, paginate, count, updateID, updateBatch, deleteID, deleteBatch
    func signup(req: Request) throws -> EventLoopFuture<NewSession>
    func signupBatch(req: Request) throws -> EventLoopFuture<[NewSession]>
    func login(req: Request) throws -> EventLoopFuture<NewSession>
}

protocol TeamPlayerSectionProtocol {
    func addPlayerToTeam(req: Request) throws -> EventLoopFuture<Team> // Request Contains: teamID, PlayerID or Player
    func registerNewPlayer(req: Request) throws -> EventLoopFuture<Team> // Request Contains: Player
    func setTrainer(req: Request) throws -> EventLoopFuture<Team> // Request Contains: Player
    func activatePlayer(req: Request) throws -> EventLoopFuture<Player> // Request Contains: Team ID + New number ID/Data
    func updatePlayerNumber(req: Request) throws -> EventLoopFuture<Player> // Request Contains: Team ID + Player
    func updatePlayerEmail(req: Request) throws -> EventLoopFuture<Player> // Request Contains: Team ID + Player

    
}

protocol RefereeProtocol {
    func assignReferee(req: Request) throws -> EventLoopFuture<Player> // Request Contains: Player
    func registerGameEvent(req: Request) throws -> EventLoopFuture<Player> // Request Contains: GameID + MatchEvent
}


protocol PublicSection {
//    func getAllLiveScores(req: Request) throws -> EventLoopFuture<[LiveScore]> // Request Contains: GameID +
//    func getleagueLiveScores(req: Request) throws -> EventLoopFuture<[LiveScore]> // Request Contains: LeagueID
//    func leagueRankings(req: Request) throws -> EventLoopFuture<Rankings> // Request Contains: LeagueID
}

protocol MessengerProtocol {
    // Make conversations, messages
}

protocol MailingProtocol {
    func welcomeMail(req: Request) throws -> EventLoopFuture<Bool>
    func welcomeBillingMail(req: Request) throws -> EventLoopFuture<Bool>
    func sendEmail(to: String, template: EmailTemplate)
    func saveMailRecord(id: UUID) -> UUID // Replace with Mail Model Flow
}

struct Rankings: Codable {}

enum InitialContact: Codable {
    case google
    case facebook
    case referrer(String)
    
    var rawValue: String {
        switch self {
        case .google:
            return "google"
        case .facebook:
            return "facebook"
        case .referrer(let referrerString):
            return "referrer:\(referrerString)"
        }
    }
    
    init(rawValue: String) {
        let components = rawValue.components(separatedBy: ":")
        switch components[0] {
        case "google":
            self = .google
        case "facebook":
            self = .facebook
        case "referrer" where components.count > 1:
            self = .referrer(components[1])
        default:
            // Handle unexpected case or throw an error
            self = .google // Default case, consider proper handling
        }
    }
    
    // Codable conformance
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue: rawValue)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

enum ClubType: String, Codable, LosslessStringConvertible {
    case privat
    case verein
    
    init?(_ description: String) {
        self.init(rawValue: description)
    }
    
    var description: String {
        return self.rawValue
    }
}

enum EmailTemplate: String, Codable {
    case welcome
    case billing
}


