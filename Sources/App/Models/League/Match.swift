//
//  File.swift
//  
//
//  Created by Alon Yakoby on 24.04.24.
//

import Foundation
import Fluent
import Vapor

struct MatchDetails: Codable {
    var gameday: Int
    var date: Date?
    var stadium: UUID?
}

struct Score: Codable {
    var home: Int
    var away: Int
    
    var displayText: String {
        return "\(home):\(away)"
    }
}

final class Match: Model, Content, Codable {
    static let schema = "matches"

    // PRE GAME
    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.details) var details: MatchDetails
    @Parent(key: FieldKeys.homeTeam) var homeTeam: Team
    @Parent(key: FieldKeys.awayTeam) var awayTeam: Team
    @OptionalParent(key: FieldKeys.referee) var referee: Referee?
    @OptionalParent(key: FieldKeys.season) var season: Season?
    
    @Children(for: \.$match) var events: [MatchEvent] // []
    
    @Field(key: FieldKeys.score) var score: Score // 0 - 0
    @Field(key: FieldKeys.status) var status: GameStatus // pending
    
    // MID GAME
    @Field(key: FieldKeys.firstHalfStartDate) var firstHalfStartDate: Date?
    @Field(key: FieldKeys.secondHalfStartDate) var secondHalfStartDate: Date?
    
    // POST GAME
    @OptionalField(key: FieldKeys.bericht) var bericht: String?
    
    enum GameStatus: String, Codable {
        case pending, first, second, halftime, completed
    }

    enum FieldKeys {
        static var id: FieldKey { "id" }
        static var bericht: FieldKey { "bericht" }
        static var homeTeam: FieldKey { "homeTeam" }
        static var awayTeam: FieldKey { "awayTeam" }
        static var season: FieldKey { "season" }
        static var details: FieldKey { "details" }
        static var score: FieldKey { "score" }
        static var status: FieldKey { "status" }
        static var referee: FieldKey { "referee" }
        
        static var firstHalfStartDate: FieldKey { "firstHalfStartDate" }
        static var secondHalfStartDate: FieldKey { "secondHalfStartDate" }
    }

    init() {}

    init(id: UUID? = nil, details: MatchDetails, homeTeamId: UUID, awayTeamId: UUID, score: Score, status: GameStatus, bericht: String? = nil, refereeId: UUID? = nil, seasonId: UUID? = nil, firstHalfStartDate: Date? = nil, secondHalfStartDate: Date? = nil) {
        self.id = id
        self.details = details
        self.$homeTeam.id = homeTeamId
        self.$awayTeam.id = awayTeamId
        self.score = score
        self.status = status
        self.bericht = bericht
        self.$referee.id = refereeId
        self.$season.id = seasonId
        self.firstHalfStartDate = firstHalfStartDate
        self.secondHalfStartDate = secondHalfStartDate
    }
}

// Match Migration
extension MatchMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Match.schema)
            .id()
            .field(Match.FieldKeys.details, .json, .required)
            .field(Match.FieldKeys.homeTeam, .uuid, .required, .references(Team.schema, .id))
            .field(Match.FieldKeys.awayTeam, .uuid, .required, .references(Team.schema, .id))
            .field(Match.FieldKeys.referee, .uuid, .references(Referee.schema, .id))
            .field(Match.FieldKeys.season, .uuid, .references(Season.schema, .id))
            .field(Match.FieldKeys.score, .json, .required)
            .field(Match.FieldKeys.status, .string, .required)
            .field(Match.FieldKeys.firstHalfStartDate, .date)
            .field(Match.FieldKeys.secondHalfStartDate, .date)
            .field(Match.FieldKeys.bericht, .string)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Match.schema).delete()
    }
}

extension Match: Mergeable {
    func merge(from other: Match) -> Match {
        var merged = self
        merged.id = other.id
        merged.details = other.details
        merged.$homeTeam.id = other.$homeTeam.id
        merged.$awayTeam.id = other.$awayTeam.id
        merged.score = other.score
        merged.status = other.status
        merged.bericht = other.bericht
        merged.$referee.id = other.$referee.id
        merged.$season.id = other.$season.id
        merged.events = other.events
        merged.firstHalfStartDate = other.firstHalfStartDate
        merged.secondHalfStartDate = other.secondHalfStartDate
        return merged
    }
}


/*
final class Match: Model, Content, Codable {
    static let schema = "matches"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.details) var details: MatchDetails
    @Field(key: FieldKeys.actualGameStart) var actualGameStart: Date?
    @Field(key: FieldKeys.currentHalf) var currentHalf: GameTime?
    @Field(key: FieldKeys.score) var score: Score
    @OptionalField(key: FieldKeys.bericht) var bericht: String?
    @OptionalParent(key: FieldKeys.refereeId) var referee: Referee?
    @Children(for: \.$match) var season: [MatchEvent]
    @Children(for: \.$match) var events: [MatchEvent]

    enum GameTime: String, Codable {
        case first, second, toBegin, halftime, completed
    }

    enum FieldKeys {
        static var id: FieldKey { "id" }
        static var details: FieldKey { "details" }
        static var actualGameStart: FieldKey { "actualGameStart" }
        static var currentHalf: FieldKey { "currentHalf" }
        static var score: FieldKey { "score" }
        static var bericht: FieldKey { "bericht" }
        static var refereeId: FieldKey { "refereeId" }
    }

    init() {}

    init(id: UUID? = nil, details: MatchDetails, actualGameStart: Date?, currentHalf: GameTime?, score: Score, bericht: String?, refereeId: UUID?) {
        self.id = id
        self.details = details
        self.actualGameStart = actualGameStart
        self.currentHalf = currentHalf
        self.score = score
        self.bericht = bericht
        self.$referee.id = refereeId
    }
}

// Match Migration
extension MatchMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Match.schema)
            .field(Match.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Match.FieldKeys.details, .json, .required)
            .field(Match.FieldKeys.actualGameStart, .datetime)
            .field(Match.FieldKeys.currentHalf, .string)
            .field(Match.FieldKeys.score, .json, .required)
            .field(Match.FieldKeys.bericht, .string)
            .field(Match.FieldKeys.refereeId, .uuid, .required, .references(Referee.schema, Referee.FieldKeys.id))
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Match.schema).delete()
    }
}

*/
