//
//  File.swift
//  
//
//  Created by Alon Yakoby on 23.04.24.
//

import Foundation
import Fluent
import Vapor

struct Hero: Codable {
    let title: String?
    let subtitle: String?
    let content: String?
    let image: String?
    let href: String?
}

struct SliderData: Codable {
    var id: UUID?
    let image: String
    let title: String
    let description: String
    let newsID: UUID?
}

// POST BODY
struct NewSlideData: Content {
    let image: String
    let title: String
    let description: String
    let newsID: UUID?
}

struct HomepageData: Codable {
    let wochenbericht: String
    let youtubeLink: String?
    var sliderdata: [SliderData]
}

// MARK: - League Model Extension

extension League {
    /// Checks all slides in `homepagedata` and assigns a new UUID to any slide that is missing an id.
    func ensureSliderIDs() {
        guard var homepage = self.homepagedata else { return }
        homepage.sliderdata = homepage.sliderdata.map { slider in
            var mutableSlider = slider
            if mutableSlider.id == nil {
                mutableSlider.id = UUID()
            }
            return mutableSlider
        }
        self.homepagedata = homepage
    }
}


final class League: Model, Content, Codable {
    static let schema = "leagues"

    @ID(custom: FieldKeys.id) var id: UUID?
    @OptionalField(key: FieldKeys.state) var state: Bundesland?

    @OptionalField(key: FieldKeys.code) var code: String?

    @OptionalField(key: FieldKeys.homepageData) var homepagedata: HomepageData?
    
    @OptionalField(key: FieldKeys.hourly) var hourly: Double?
    @OptionalField(key: FieldKeys.youtube) var youtube: String?
    @OptionalField(key: FieldKeys.teamcount) var teamcount: Int?
    @OptionalField(key: FieldKeys.visibility) var visibility: Bool?
    @Field(key: FieldKeys.name) var name: String
    @Children(for: \.$league) var teams: [Team]
    @Children(for: \.$league) var seasons: [Season]
    
    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var state: FieldKey { "state" }
        static var hourly: FieldKey { "hourly" }
        static var teamcount: FieldKey { "teamcount" }
        static var code: FieldKey { "code" }
        static var name: FieldKey { "name" }
        static var homepageData: FieldKey { "homepageData" }
        static var youtube: FieldKey { "youtube" }
        static var visibility: FieldKey { "visibility" }
    }

    init() {}

    init(id: UUID? = nil, state: Bundesland?, teamcount: Int?, code: String, name: String, wochenbericht: String? = nil, homepagedata: HomepageData? = nil, youtube: String? = nil, visibility: Bool?) {
        self.id = id
        self.state = state
        self.code = code
        self.name = name
        self.teamcount = teamcount ?? 14
        self.homepagedata = homepagedata
        self.youtube = youtube
        self.visibility = visibility
    }
}

extension League: Mergeable {
    func merge(from other: League) -> League {
        var merged = self
        merged.id = other.id
        merged.state = other.state
        merged.hourly = other.hourly
        merged.code = other.code
        merged.name = other.name
        merged.teamcount = other.teamcount
        merged.homepagedata = other.homepagedata
        merged.youtube = other.youtube
        return merged
    }
}


// League Migration
extension LeagueMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(League.schema)
            .field(League.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(League.FieldKeys.state, .string, .required)
            .field(League.FieldKeys.code, .string)
            .field(League.FieldKeys.hourly, .double)
            .field(League.FieldKeys.teamcount, .int)
            .field(League.FieldKeys.visibility, .bool)
            .field(League.FieldKeys.homepageData, .json)
            .field(League.FieldKeys.youtube, .string)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(League.schema).delete()
    }
}

extension League {
    func createSeason(db: Database, numberOfRounds: Int, switchBool: Bool) -> EventLoopFuture<Void> {
        guard let leagueID = self.id else {
            return db.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "League ID is required"))
        }

        let currentYear = Calendar.current.component(.year, from: Date.viennaNow)
        let nextYear = currentYear + 1
        let seasonName = "\(currentYear)/\(nextYear)"
        let season = Season(name: seasonName, details: 0, primary: false)
        season.$league.id = leagueID

        return season.save(on: db).flatMap {
            self.$teams.query(on: db).all().flatMap { teams in
                guard teams.count > 1 else {
                    return db.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "League must have more than one team"))
                }

                var matches: [Match] = []
                let isOddTeamCount = teams.count % 2 != 0
                var teamsCopy = teams

                if isOddTeamCount {
                    let byeTeam = Team(id: UUID(), sid: "", userId: nil, leagueId: nil, leagueCode: nil, points: 0, coverimg: "", logo: "", teamName: "Bye", foundationYear: "", membershipSince: "", averageAge: "", coach: nil, captain: "", trikot: Trikot(home: "", away: ""), balance: 0.0, referCode: "", usremail: "", usrpass: "", usrtel: "")
                    teamsCopy.append(byeTeam)
                }

                var gameDay = 1
                let totalGameDays = (teamsCopy.count - 1) * numberOfRounds

                for round in 0..<numberOfRounds {
                    var homeAwaySwitch = switchBool

                    for roundIndex in 0..<(teamsCopy.count - 1) {
                        for matchIndex in 0..<(teamsCopy.count / 2) {
                            let homeTeamIndex = (roundIndex + matchIndex) % (teamsCopy.count - 1)
                            var awayTeamIndex = (teamsCopy.count - 1 - matchIndex + roundIndex) % (teamsCopy.count - 1)

                            if matchIndex == 0 {
                                awayTeamIndex = teamsCopy.count - 1
                            }

                            var homeTeam = teamsCopy[homeTeamIndex]
                            var awayTeam = teamsCopy[awayTeamIndex]

                            if homeTeam.teamName == "Bye" || awayTeam.teamName == "Bye" {
                                continue
                            }

                            if homeAwaySwitch {
                                swap(&homeTeam, &awayTeam)
                            }

                            let match = Match(
                                details: MatchDetails(gameday: gameDay, date: nil, stadium: nil, location: "Nicht Zugeordnet"),
                                homeTeamId: homeTeam.id!,
                                awayTeamId: awayTeam.id!,
                                homeBlanket: Blankett(name: homeTeam.teamName, dress: homeTeam.trikot.home, logo: homeTeam.logo, players: [], coach: homeTeam.coach),
                                awayBlanket: Blankett(name: awayTeam.teamName, dress: awayTeam.trikot.away, logo: awayTeam.logo, players: [], coach: awayTeam.coach),
                                score: Score(home: 0, away: 0),
                                status: .pending
                            )

                            match.$season.id = season.id!
                            matches.append(match)
                        }
                        gameDay += 1
                        if gameDay > totalGameDays {
                            gameDay = 1
                        }
                    }

                    homeAwaySwitch.toggle()
                }

                return matches.create(on: db).transform(to: ())
            }
        }
    }
}


