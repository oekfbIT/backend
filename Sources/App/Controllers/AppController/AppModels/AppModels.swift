//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 19.10.25.
//

import Foundation
import Fluent
import Vapor

struct AppModels {
    
    enum FollowType: String, Codable {
        case team
        case player
        case trainer
        case league
    }
    
    struct FollowContract: Content,  Codable {
        let id: UUID
        let type: FollowType
        let name: String
        let subtitle: String?
        let userID: UUID
        let itemID: UUID
        let createdAt: Date
    }
    
    struct AppTeam: Content, Codable {
        let id: UUID
        let sid: String
        let league: AppLeagueOverview
        let points: Int
        let logo: String
        let teamImage: String
        let name: String
        let foundation: String
        let membership: String
        let coach: Trainer
        let altCoach: Trainer?
        let captain: UUID
        let trikot: Trikot
        let balance: Double?
        let players: [AppPlayer]
        let stats: TeamStats?
        let form: [FormItem]?  // NEW
    }
    
    struct AppTeamOverview: Content, Codable {
        let id: UUID
        let sid: String
        let league: AppLeagueOverview
        let points: Int
        let logo: String
        let name: String
        let stats: TeamStats?
        
    }

    struct AppUser: Content, Codable {
        let id: UUID
        let type: UserType
        let firstname: String
        let lastname: String
        let email: String
    }
    struct AppToken: Content, Codable {
        let id: UUID
        let user: AppUser
        let value: String
        let source: SessionSource
        let expiresAt: Date?
        let updatedAt: Date?
        
    }
    
    struct AppLeague: Content, Codable {
        let id: UUID
        let code: String
        let hourly: String
        let state: Bundesland
        let visibility: Bool
        let name: String
        let count: Int
        let teams: [AppTeamOverview]
        let table: [TableItem]
    }
    
    struct AppLeagueOverview: Content, Codable {
        let id: UUID
        let name: String
        let code: String
        let state: Bundesland
    }
    
    struct AppSeason: Content, Codable {
        let id: String
        let league: String
        let leagueId: UUID
        let name: String
    }

    struct AppPlayer: Content, Codable {
        let id: UUID
        let sid: String
        let name: String
        let number: String
        let nationality: String
        let eligilibity: PlayerEligibility
        let image: String
        let status: Bool
        let team: AppTeamOverview
        let email: String
        let balance: Double
        let events: [AppMatchEvent]
        let stats: PlayerStats?
        let nextMatch: [NextMatch]
        let position: String
        let birthDate: String

    }

    struct AppPlayerOverview: Content, Codable {
        let id: UUID
        let sid: String
        let name: String
        let number: String
        let nationality: String
        let eligilibity: PlayerEligibility
        let image: String
        let status: Bool
        let team: AppTeamOverview
        let nextMatch: [NextMatch]
    }

    struct AppPlayerMatchEventWrapper: Content, Codable {
        let id: UUID
        let sid: String
        let name: String
        let number: String
        let nationality: String
        let eligilibity: PlayerEligibility
        let image: String
    }

    
    struct AppMatchEvent: Content, Codable  {
        let id: UUID?
        let headline: Matchheadline
        let type: MatchEventType
        let player: AppPlayerMatchEventWrapper
        let minute: Int
        let matchID: UUID
        let name: String?
        let image: String?
        let number: String?
        let assign: MatchAssignment?
        let ownGoal: Bool?
    }
    
    struct Matchheadline: Content, Codable {
        let homeID: UUID
        let homeName: String
        let homeLogo: String
        let gameday: Int
        let date: Date
        let awayID: UUID
        let awayName: String
        let awayLogo: String
    }
    
    struct AppMatch: Content, Codable {
        let id: UUID
        let details: MatchDetails
        let score: Score
        let season: AppSeason
        let away: AppTeamOverview
        let home: AppTeamOverview
        let homeBlanket: Blankett
        let awayBlanket: Blankett
        let events: [AppMatchEvent]
        let status: GameStatus
        let firstHalfStartDate: Date?
        let secondHalfStartDate: Date?
        let firstHalfEndDate: Date?
        let secondHalfEndDate: Date?
        let homeForm: [FormItem]?
        let awayForm: [FormItem]?
    }
    
    struct AppMatchOverview: Content, Codable {
        let id: UUID
        let details: MatchDetails
        let score: Score
        let season: AppSeason
        let away: AppTeamOverview
        let home: AppTeamOverview
        let homeBlanket: MiniBlankett
        let awayBlanket: MiniBlankett
        let status: GameStatus
    }
    
}

/*

// MARK: Team Public
MARK: Player Public
MARK: League Public
leaguesIndex
MARK: Season Public
MARK: Gameday Public
MARK: Match Public
MARK: MatchEvent Public
MARK: Referee Public
MARK: Statdium Public
MARK: Search Public

MARK: Conversation Public
MARK: Document Controller Public
MARK: Authentication Public
MARK: Transfers Public
MARK: Transfer Settings Public
MARK: Postpone Request Public
 
MARK: Generic
Get all Following
 
MARK: User
Follow
*/

        /*
Screens
// MARK: Authentication
Login Player
Sign Up Player
Upload ID
Login Team
// MARK: Leagues + Detail
League Table + Form
Fixtures
News
Matchdetail
Player stats
Team stats
Transfers
Seasons
         */
