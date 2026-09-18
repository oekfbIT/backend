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
        let shortName: String?
        let foundation: String
        let membership: String
        let coach: Trainer
        let altCoach: Trainer?
        let captain: UUID
        let trikot: Trikot
        let balance: Double?
        let cancelled: Int?
        let postponed: Int?
        let players: [AppPlayer]
        let stats: TeamStats?
        var seasonStats: TeamStats? = nil
        let form: [FormItem]?  // NEW
    }
    
    struct AppTeamOverview: Content, Codable {
        let id: UUID
        let sid: String
        let league: AppLeagueOverview
        let points: Int
        let logo: String
        let name: String
        let shortName: String?
        let stats: TeamStats?
        var seasonStats: TeamStats? = nil
        
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
        let logo: String?
        let teamCount: Int?
        let seasonName: String?
        let category: LeagueCategory?

        init(
            id: UUID,
            name: String,
            code: String,
            state: Bundesland,
            logo: String?,
            teamCount: Int? = nil,
            seasonName: String? = nil,
            category: LeagueCategory? = nil
        ) {
            self.id = id
            self.name = name
            self.code = code
            self.state = state
            self.logo = logo
            self.teamCount = teamCount
            self.seasonName = seasonName
            self.category = category
        }
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
        let seasonStats: PlayerStats?
        let matches: [PublicSeasonMatches]?
        let nextMatch: [NextMatch]
        let position: String
        let birthDate: String

    }

    /// Public player payload used by the unauthenticated app experience. Keep
    /// this allowlist separate from `AppPlayer`: account email, balance, and
    /// date of birth must never be serialized by a public route.
    struct PublicAppPlayer: Content, Codable {
        let id: UUID
        let sid: String
        let name: String
        let number: String
        let nationality: String
        let eligilibity: PlayerEligibility
        let image: String
        let status: Bool
        let team: AppTeamOverview
        let events: [AppMatchEvent]
        let stats: PlayerStats?
        let seasonStats: PlayerStats?
        let matches: [PublicSeasonMatches]?
        let nextMatch: [NextMatch]
        let position: String

        init(_ player: AppPlayer) {
            id = player.id
            sid = player.sid
            name = player.name
            number = player.number
            nationality = player.nationality
            eligilibity = player.eligilibity
            image = player.image
            status = player.status
            team = player.team
            events = player.events
            stats = player.stats
            seasonStats = player.seasonStats
            matches = player.matches
            nextMatch = player.nextMatch
            position = player.position
        }
    }

    /// Public team payload. Financial data and trainer contact details remain
    /// available only from authenticated, ownership-checked endpoints.
    struct PublicAppTeam: Content, Codable {
        let id: UUID
        let sid: String
        let league: AppLeagueOverview
        let points: Int
        let logo: String
        let teamImage: String
        let name: String
        let shortName: String?
        let foundation: String
        let membership: String
        let coach: PublicTrainer
        let altCoach: PublicTrainer?
        let captain: UUID
        let trikot: Trikot
        let cancelled: Int?
        let postponed: Int?
        let players: [PublicAppPlayer]
        let stats: TeamStats?
        var seasonStats: TeamStats?
        let form: [FormItem]?

        init(_ team: AppTeam) {
            id = team.id
            sid = team.sid
            league = team.league
            points = team.points
            logo = team.logo
            teamImage = team.teamImage
            name = team.name
            shortName = team.shortName
            foundation = team.foundation
            membership = team.membership
            coach = team.coach.asPublic()
            altCoach = team.altCoach?.asPublic()
            captain = team.captain
            trikot = team.trikot
            cancelled = team.cancelled
            postponed = team.postponed
            players = team.players.map(PublicAppPlayer.init)
            stats = team.stats
            seasonStats = team.seasonStats
            form = team.form
        }
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
        let firstHalfStartDate: Date?
        let secondHalfStartDate: Date?
        
        
        init(id: UUID, details: MatchDetails, score: Score, season: AppSeason, away: AppTeamOverview, home: AppTeamOverview, homeBlanket: MiniBlankett, awayBlanket: MiniBlankett, status: GameStatus, firstHalfStartDate: Date? = nil, secondHalfStartDate: Date? = nil) {
            self.id = id
            self.details = details
            self.score = score
            self.season = season
            self.away = away
            self.home = home
            self.homeBlanket = homeBlanket
            self.awayBlanket = awayBlanket
            self.status = status
            self.firstHalfStartDate = firstHalfStartDate
            self.secondHalfStartDate = secondHalfStartDate
        }
        
        
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
