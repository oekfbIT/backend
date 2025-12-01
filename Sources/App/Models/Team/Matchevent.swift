//
//  File.swift
//  
//
//  Created by Alon Yakoby on 24.04.24.
//

import Foundation
import Fluent
import Vapor

enum MatchAssignment: String, Codable {
    case home, away
}

final class MatchEvent: Model, Content, Codable {
    static let schema = "match_events"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.type) var type: MatchEventType

    // Player may be deleted → OptionalParent
    @OptionalParent(key: FieldKeys.playerId) var player: Player?

    @Field(key: FieldKeys.minute) var minute: Int
    @Parent(key: FieldKeys.match) var match: Match

    @OptionalField(key: FieldKeys.name) var name: String?
    @OptionalField(key: FieldKeys.image) var image: String?
    @OptionalField(key: FieldKeys.number) var number: String?
    @OptionalField(key: FieldKeys.assign) var assign: MatchAssignment?
    @OptionalField(key: FieldKeys.ownGoal) var ownGoal: Bool?

    enum FieldKeys {
        static let id: FieldKey = "id"
        static let type: FieldKey = "type"
        static let match: FieldKey = "match"
        static let playerId: FieldKey = "playerId"
        static let minute: FieldKey = "minute"

        static let name: FieldKey = "name"
        static let image: FieldKey = "image"
        static let number: FieldKey = "number"
        static let assign: FieldKey = "assign"
        static let ownGoal: FieldKey = "ownGoal"
    }

    init() {}

    init(
        id: UUID? = nil,
        matchId: Match.IDValue,
        type: MatchEventType,
        playerId: UUID? = nil,
        minute: Int,
        name: String?,
        image: String?,
        number: String?,
        assign: MatchAssignment? = nil,
        ownGoal: Bool? = nil
    ) {
        self.id = id
        self.$match.id = matchId
        self.type = type
        self.minute = minute
        self.$player.id = playerId
        self.name = name
        self.image = image
        self.number = number
        self.assign = assign
        self.ownGoal = ownGoal
    }
}

// MatchEvent Migration
extension MatchEventMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(MatchEvent.schema)
            .field(MatchEvent.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(MatchEvent.FieldKeys.type, .string, .required)
            // playerId is OPTIONAL, and FK uses ON DELETE SET NULL semantics
            .field(MatchEvent.FieldKeys.playerId, .uuid,
                   .references(Player.schema, Player.FieldKeys.id, onDelete: .setNull))
            .field(MatchEvent.FieldKeys.match, .uuid, .required,
                   .references(Match.schema, Match.FieldKeys.id, onDelete: .cascade))
            .field(MatchEvent.FieldKeys.minute, .int, .required)
            .field(MatchEvent.FieldKeys.name, .string)
            .field(MatchEvent.FieldKeys.image, .string)
            .field(MatchEvent.FieldKeys.number, .string)
            .field(MatchEvent.FieldKeys.assign, .string)
            .field(MatchEvent.FieldKeys.ownGoal, .bool)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(MatchEvent.schema).delete()
    }
}

// MARK: - MatchEvent → AppMatchEvent (SAFE: no `$player.get`)

extension MatchEvent {
    func toAppMatchEvent(on req: Request) async throws -> AppModels.AppMatchEvent {
        // 1️⃣ Resolve player manually by id (no relation loader)
        let player: Player?
        if let pid = self.$player.id {
            player = try await Player.find(pid, on: req.db)
        } else {
            player = nil
        }

        // 2️⃣ Resolve team manually via player's team id
        let team: Team?
        if let player = player, let teamId = player.$team.id {
            team = try await Team.find(teamId, on: req.db)
        } else {
            team = nil
        }

        // 3️⃣ League overview
        let leagueOverview: AppModels.AppLeagueOverview
        if let league = team?.league {
            leagueOverview = try league.toAppLeagueOverview()
        } else {
            leagueOverview = AppModels.AppLeagueOverview(
                id: UUID(),
                name: "Unknown",
                code: "",
                state: .wien
            )
        }

        // 4️⃣ Team overview (with stats if you want to keep that)
        let teamOverview: AppModels.AppTeamOverview
        if let team = team {
            teamOverview = try await team
                .toAppTeamOverview(league: leagueOverview, req: req)
                .get()
        } else {
            teamOverview = AppModels.AppTeamOverview(
                id: UUID(),
                sid: "",
                league: leagueOverview,
                points: 0,
                logo: "",
                name: "Unknown Team",
                stats: nil
            )
        }

        // 5️⃣ Player wrapper: use real player if exists, otherwise fallback
        let appPlayer = try player?.toAppPlayerOverviewMatchEvent(team: teamOverview)
        let fallbackPlayer = try error_player.toAppPlayerOverviewMatchEvent(team: teamOverview)

        // 6️⃣ Headline: you *can* still use relation loaders for Match here
        let match = try await self.$match.get(on: req.db)
        let homeTeam = try await match.$homeTeam.get(on: req.db)
        let awayTeam = try await match.$awayTeam.get(on: req.db)

        let headline = AppModels.Matchheadline(
            homeID: try homeTeam.requireID(),
            homeName: homeTeam.teamName,
            homeLogo: homeTeam.logo,
            gameday: match.details.gameday,
            date: match.details.date ?? Date(),
            awayID: try awayTeam.requireID(),
            awayName: awayTeam.teamName,
            awayLogo: awayTeam.logo
        )

        return AppModels.AppMatchEvent(
            id: try self.requireID(),
            headline: headline,
            type: self.type,
            player: appPlayer ?? fallbackPlayer,
            minute: self.minute,
            matchID: self.$match.id,
            name: self.name,
            image: self.image,
            number: self.number,
            assign: self.assign,
            ownGoal: self.ownGoal
        )
    }
}



// Fallback "error" player, used if the real player is deleted or missing
let error_app_player = AppModels.AppPlayer(
    id: UUID(),
    sid: "00000",
    name: "ERROR",
    number: "0",
    nationality: "ERROR",
    eligilibity: .Gesperrt,
    image: "ERROR",
    status: false,
    team: AppModels.AppTeamOverview(
        id: UUID(),
        sid: "",
        league: AppModels.AppLeagueOverview(
            id: UUID(),
            name: "",
            code: "",
            state: .ausgetreten
        ),
        points: 0,
        logo: "",
        name: "",
        stats: nil
    ),
    email: "ERROR",
    balance: 0.0,
    events: [],
    stats: nil,
    nextMatch: [],
    position: "ERROR",
    birthDate: "ERROR"
)

let error_player = Player(
    id: UUID(), 
    sid: "ERROR",
    image: "ERROR",
    team_oeid: "ERROR",
    email: "ERROR",
    balance: 0,
    name: "ERROR",
    number: "ERROR",
    birthday: "ERROR",
    teamID: nil,
    nationality: "ERROR",
    position: "ERROR",
    eligibility: .Gesperrt,
    registerDate: "ERROR",
    identification: "ERROR",
    status: true
)

