//
//  AdminController+LeagueRoutes.swift
//  oekfbbackend
//
//  Assumptions:
//  - This file is mounted under your `AdminController` routes group (authed + AdminOnlyMiddleware).
//  - `Bundesland` is `Codable` and matches your DB representation.
//  - `LeagueMigration` currently marks `state` as `.required`, so `CreateLeagueRequest` includes it.
//  - `HomepageData.wochenbericht` is required, so when we create homepagedata implicitly we default it to "".
//

import Foundation
import Vapor
import Fluent

// MARK: - Admin League Routes
extension AdminController {

    func setupLeagueRoutes(on root: RoutesBuilder) {
        let leagues = root.grouped("leagues")

        // GET /admin/leagues
        leagues.get(use: getAllLeagues)

        // POST /admin/leagues
        leagues.post(use: createLeague)

        // GET /admin/leagues/:id
        leagues.get(":id", use: getLeagueByID)

        // PATCH /admin/leagues/:id
        leagues.patch(":id", use: patchLeague)

        // DELETE /admin/leagues/:id
        leagues.delete(":id", use: deleteLeague)

        // GET /admin/leagues/:id/seasons
        leagues.get(":id", "seasons", use: getLeagueSeasons)

        // POST /admin/leagues/:id/slides
        leagues.post(":id", "slides", use: addSlideToLeague)
        leagues.delete(":id", "slides", ":slideId", use: deleteSlideFromLeague)
        
        leagues.post(":id", "seasons", use: createSeasonForLeague)

        // POST /admin/leagues/:id/seasons/:seasonId/matches
        leagues.post(":id", "seasons", ":seasonId", "matches", use: addMatchesToSeasonForLeague)

        // POST /admin/leagues/:id/matches
        leagues.post(":id", "matches", use: addSingleMatchToLeague)

        // GET /admin/leagues/:id/teams
        leagues.get(":id", "teams", use: getAllTeamsForLeague)

        leagues.get(":id", "bundle", use: getLeagueBundle)


    }
}

// MARK: - Requests
extension AdminController {
    /// Only the mandatory values required to create a League.
    struct CreateLeagueRequest: Content {
        let name: String
        let state: Bundesland
    }

    /// Patch-style updates: send only what you want to change.
    struct PatchLeagueRequest: Content {
        let state: Bundesland?
        let code: String?
        let homepagedata: HomepageData?
        let hourly: Double?
        let youtube: String?
        let teamcount: Int?
        let visibility: Bool?
        let name: String?
    }

    /// Add a single slide to the league's `homepagedata.sliderdata`.
    struct AddSlideRequest: Content {
        let image: String
        let title: String
        let description: String
        let newsID: UUID?
    }
    
    struct CreateSeasonRequest: Content {
        let seasonName: String
        let numberOfRounds: Int
        let switchBool: Bool
    }

    struct AddMatchesToSeasonRequest: Content {
        let numberOfRounds: Int
        let switchBool: Bool
    }

    struct AddSingleMatchRequest: Content {
        let seasonId: UUID
        let homeTeamId: UUID
        let awayTeamId: UUID

        /// Optional fields; if omitted we default them.
        let gameday: Int?
        let date: Date?
        let stadiumId: UUID?
        let location: String?
        let homeDress: String?
        let awayDress: String?
        let status: GameStatus?
    }

    struct LeagueBundleResponse: Content {
        let league: League
        let teams: [AppModels.AppTeamOverview]
        let seasons: [Season]
    }

}

// MARK: - Handlers
extension AdminController {

    // 1) GET /admin/leagues
    // GET /admin/leagues
    func getAllLeagues(req: Request) async throws -> [AppModels.AppLeagueOverview] {
        let leagues = try await League.query(on: req.db)
            .sort(\.$name, .ascending)
            .all()

        return try leagues.map { try $0.toAppLeagueOverview() }
    }

    // 2) POST /admin/leagues
    func createLeague(req: Request) async throws -> League {
        let body = try req.content.decode(CreateLeagueRequest.self)

        let trimmedName = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw Abort(.badRequest, reason: "League name is required.")
        }

        let league = League(
            id: nil,
            state: body.state,
            teamcount: nil,
            code: "",
            name: trimmedName,
            wochenbericht: nil,
            homepagedata: nil,
            youtube: nil,
            visibility: true
        )

        // Keep nameLower consistent
        league.nameLower = trimmedName.lowercased()

        try await league.save(on: req.db)
        return league
    }

    // 3) GET /admin/leagues/:id
    func getLeagueByID(req: Request) async throws -> League {
        let league = try await requireLeague(req: req)
        return league
    }

    // 4) PATCH /admin/leagues/:id
    func patchLeague(req: Request) async throws -> League {
        let league = try await requireLeague(req: req)
        let patch = try req.content.decode(PatchLeagueRequest.self)

        if let state = patch.state { league.state = state }
        if let code = patch.code { league.code = code }
        if let homepagedata = patch.homepagedata { league.homepagedata = homepagedata }
        if let hourly = patch.hourly { league.hourly = hourly }
        if let youtube = patch.youtube { league.youtube = youtube }
        if let teamcount = patch.teamcount { league.teamcount = teamcount }
        if let visibility = patch.visibility { league.visibility = visibility }

        if let name = patch.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "Name cannot be empty.")
            }
            league.name = trimmed
            league.nameLower = trimmed.lowercased()
        }

        try await league.save(on: req.db)
        return league
    }

    // 5) POST /admin/leagues/:id/slides
    func addSlideToLeague(req: Request) async throws -> League {
        let league = try await requireLeague(req: req)
        let body = try req.content.decode(AddSlideRequest.self)

        let trimmedTitle = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = body.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw Abort(.badRequest, reason: "Slide title is required.")
        }
        guard !trimmedDesc.isEmpty else {
            throw Abort(.badRequest, reason: "Slide description is required.")
        }

        // Ensure homepage exists
        if league.homepagedata == nil {
            league.homepagedata = HomepageData(
                wochenbericht: "",
                youtubeLink: nil,
                sliderdata: []
            )
        }

        // Ensure all existing slides have IDs
        league.ensureSliderIDs()

        // Append new slide with a fresh UUID
        var homepage = league.homepagedata!
        let slide = SliderData(
            id: UUID(),
            image: body.image,
            title: trimmedTitle,
            description: trimmedDesc,
            newsID: body.newsID
        )
        homepage.sliderdata.append(slide)
        league.homepagedata = homepage

        try await league.save(on: req.db)
        return league
    }

    // 6) GET /admin/leagues/:id/seasons
    func getLeagueSeasons(req: Request) async throws -> [Season] {
        let league = try await requireLeague(req: req)
        let leagueID = try league.requireID()

        return try await Season.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .sort(\.$name, .ascending)
            .all()
    }
    
    func deleteSlideFromLeague(req: Request) async throws -> League {
        let league = try await requireLeague(req: req)

        guard let slideId = req.parameters.get("slideId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid slideId.")
        }

        guard var homepage = league.homepagedata else {
            throw Abort(.notFound, reason: "Homepage data not found.")
        }

        // Ensure legacy slides have IDs so deletes work reliably
        league.ensureSliderIDs()
        homepage = league.homepagedata ?? homepage

        let before = homepage.sliderdata.count
        homepage.sliderdata.removeAll { $0.id == slideId }

        guard homepage.sliderdata.count != before else {
            throw Abort(.notFound, reason: "Slide not found.")
        }

        league.homepagedata = homepage
        try await league.save(on: req.db)
        return league
    }
    
    // POST /admin/leagues/:id/seasons
    func createSeasonForLeague(req: Request) async throws -> Season {
        let league = try await requireLeague(req: req)
        let body = try req.content.decode(AdminController.CreateSeasonRequest.self)

        let trimmed = body.seasonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Season name is required.")
        }
        guard body.numberOfRounds > 0 else {
            throw Abort(.badRequest, reason: "numberOfRounds must be > 0.")
        }

        try await league.createSeason(
            db: req.db,
            seasonName: trimmed,
            numberOfRounds: body.numberOfRounds,
            switchBool: body.switchBool
        ).get()

        // Return the newest season for that league with this name
        let leagueID = try league.requireID()
        guard let season = try await Season.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .filter(\.$name == trimmed)
            .first()
        else {
            throw Abort(.internalServerError, reason: "Season created but could not be fetched.")
        }

        return season
    }

    // POST /admin/leagues/:id/seasons/:seasonId/matches
    func addMatchesToSeasonForLeague(req: Request) async throws -> HTTPStatus {
        let league = try await requireLeague(req: req)
        let body = try req.content.decode(AdminController.AddMatchesToSeasonRequest.self)

        guard let seasonId = req.parameters.get("seasonId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid seasonId.")
        }
        guard body.numberOfRounds > 0 else {
            throw Abort(.badRequest, reason: "numberOfRounds must be > 0.")
        }

        guard let season = try await Season.find(seasonId, on: req.db) else {
            throw Abort(.notFound, reason: "Season not found.")
        }

        try await league.addMatchesToSeason(
            db: req.db,
            season: season,
            numberOfRounds: body.numberOfRounds,
            switchBool: body.switchBool
        ).get()

        return .ok
    }

    // POST /admin/leagues/:id/matches
    func addSingleMatchToLeague(req: Request) async throws -> Match {
        let league = try await requireLeague(req: req)
        let body = try req.content.decode(AdminController.AddSingleMatchRequest.self)

        let leagueID = try league.requireID()

        // Ensure season belongs to this league
        guard let season = try await Season.find(body.seasonId, on: req.db) else {
            throw Abort(.notFound, reason: "Season not found.")
        }
        guard season.$league.id == leagueID else {
            throw Abort(.badRequest, reason: "Season does not belong to this league.")
        }

        // Validate teams exist + belong to league
        guard let homeTeam = try await Team.find(body.homeTeamId, on: req.db) else {
            throw Abort(.notFound, reason: "Home team not found.")
        }
        guard let awayTeam = try await Team.find(body.awayTeamId, on: req.db) else {
            throw Abort(.notFound, reason: "Away team not found.")
        }
        guard homeTeam.$league.id == leagueID, awayTeam.$league.id == leagueID else {
            throw Abort(.badRequest, reason: "Both teams must belong to this league.")
        }
        guard body.homeTeamId != body.awayTeamId else {
            throw Abort(.badRequest, reason: "Home and away team cannot be the same.")
        }

        // Optional stadium lookup
        var stadium: Stadium? = nil
        if let stadiumId = body.stadiumId {
            stadium = try await Stadium.find(stadiumId, on: req.db)
            if stadium == nil {
                throw Abort(.notFound, reason: "Stadium not found.")
            }
        }

        // Gameday default: append after last match in that season
        let seasonID = try season.requireID()
        let lastGameday = try await Match.query(on: req.db)
            .filter(\.$season.$id == seasonID)
            .first()
            .map { $0.details.gameday ?? 0 } ?? 0

        let gameday = body.gameday ?? (lastGameday + 1)

        let match = Match(
            details: MatchDetails(
                gameday: gameday,
                date: body.date,
                stadium: stadium?.id,
                location: body.location ?? "Nicht Zugeordnet"
            ),
            homeTeamId: body.homeTeamId,
            awayTeamId: body.awayTeamId,
            homeBlanket: Blankett(
                name: homeTeam.teamName,
                dress: body.homeDress ?? homeTeam.trikot.home,
                logo: homeTeam.logo,
                players: [],
                coach: homeTeam.coach
            ),
            awayBlanket: Blankett(
                name: awayTeam.teamName,
                dress: body.awayDress ?? awayTeam.trikot.away,
                logo: awayTeam.logo,
                players: [],
                coach: awayTeam.coach
            ),
            score: Score(home: 0, away: 0),
            status: body.status ?? .pending
        )

        match.$season.id = seasonID
        try await match.save(on: req.db)
        return match
    }

    // GET /admin/leagues/:id/teams
    func getAllTeamsForLeague(req: Request) async throws -> [Team] {
        let league = try await requireLeague(req: req)
        let leagueID = try league.requireID()

        return try await Team.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .sort(\.$teamName, .ascending)
            .all()
    }

    // DELETE /admin/leagues/:id
    func deleteLeague(req: Request) async throws -> HTTPStatus {
        let league = try await requireLeague(req: req)
        let leagueID = try league.requireID()

        // Guard: don't delete if there are dependent records
        let teamsCount = try await Team.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .count()

        let seasonsCount = try await Season.query(on: req.db)
            .filter(\.$league.$id == leagueID)
            .count()

        if teamsCount > 0 || seasonsCount > 0 {
            throw Abort(.conflict, reason: "League cannot be deleted while it still has teams or seasons. (teams=\(teamsCount), seasons=\(seasonsCount))")
        }

        try await league.delete(on: req.db)
        return .noContent
    }

    /// GET /admin/leagues/:id/bundle
    ///
    /// Returns a "bundle" that is ideal for detail screens:
    /// - League (full)
    /// - Teams (as AppTeamOverview)
    /// - Seasons
    func getLeagueBundle(req: Request) async throws -> LeagueBundleResponse {
        let league = try await requireLeague(req: req)
        let leagueId = try league.requireID()

        let teams = try await Team.query(on: req.db)
            .filter(\.$league.$id == leagueId)
            .sort(\.$teamName, .ascending)
            .all()

        let seasons = try await Season.query(on: req.db)
            .filter(\.$league.$id == leagueId)
            .sort(\.$name, .ascending)
            .all()

        let leagueOverview = try league.toAppLeagueOverview()

        // 🔑 IMPORTANT PART
        // Convert [EventLoopFuture<AppTeamOverview>] -> [AppTeamOverview]
        let teamOverviews: [AppModels.AppTeamOverview] = try await teams
            .map { team in
                try team.toAppTeamOverview(league: leagueOverview, req: req)
            }
            .flatten(on: req.eventLoop)
            .get()

        return LeagueBundleResponse(
            league: league,
            teams: teamOverviews,
            seasons: seasons
        )
    }


}

// MARK: - Helpers
private extension AdminController {
    func requireLeague(req: Request) async throws -> League {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid league ID.")
        }
        guard let league = try await League.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "League not found.")
        }
        return league
    }
}
