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

// MARK: - Batched event presentation (no discarded team-stat queries)
extension MatchEvent {
    static func toAppMatchEvents(_ events: [MatchEvent], on req: Request) async throws -> [AppModels.AppMatchEvent] {
        guard !events.isEmpty else { return [] }
        let matchIDs = Array(Set(events.map { $0.$match.id }))
        let playerIDs = Array(Set(events.compactMap { $0.$player.id }))
        async let matchesF = Match.query(on: req.db).filter(\.$id ~~ matchIDs)
            .with(\.$homeTeam).with(\.$awayTeam).all().get()
        async let playersF = Player.query(on: req.db).filter(\.$id ~~ playerIDs).all().get()
        let (matches, players) = try await (matchesF, playersF)
        let matchByID = Dictionary(matches.compactMap { m in m.id.map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        let playerByID = Dictionary(players.compactMap { p in p.id.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        return events.compactMap { event in
            guard let match = matchByID[event.$match.id] else { return nil }
            let player = event.$player.id.flatMap { playerByID[$0] }
            let wrapper = AppModels.AppPlayerMatchEventWrapper(
                id: event.$player.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                sid: player?.sid ?? "", name: event.name ?? player?.name ?? "Unknown",
                number: event.number ?? player?.number ?? "", nationality: player?.nationality ?? "",
                eligilibity: player?.eligibility ?? .Warten, image: event.image ?? player?.image ?? "")
            let headline = AppModels.Matchheadline(
                homeID: match.$homeTeam.id, homeName: match.homeBlanket?.name ?? match.homeTeam.teamName,
                homeLogo: match.homeBlanket?.logo ?? match.homeTeam.logo,
                gameday: match.details.gameday, date: match.details.date ?? .distantPast,
                awayID: match.$awayTeam.id, awayName: match.awayBlanket?.name ?? match.awayTeam.teamName,
                awayLogo: match.awayBlanket?.logo ?? match.awayTeam.logo)
            return AppModels.AppMatchEvent(id: event.id, headline: headline, type: event.type, player: wrapper,
                minute: event.minute, matchID: event.$match.id, name: event.name, image: event.image,
                number: event.number, assign: event.assign, ownGoal: event.ownGoal)
        }
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
            state: .ausgetreten,
            logo: nil
        ),
        points: 0,
        logo: "",
        name: "",
        shortName: "",
        stats: nil
    ),
    email: "ERROR",
    balance: 0.0,
    events: [],
    stats: nil,
    seasonStats: nil,
    matches: nil,
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
