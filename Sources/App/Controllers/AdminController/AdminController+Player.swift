//
//  AdminController+PlayerRoutes.swift
//
//  Admin endpoints for Players.
//
//  Mounted under AdminController authed + AdminOnlyMiddleware() group.
//
//  Routes:
//  - GET    /admin/players/:id
//  - GET    /admin/players/sid/:sid
//  - GET    /admin/players/:id/events
//  - POST   /admin/players/register          (multipart/form-data)
//  - PATCH  /admin/players/:id
//  - POST   /admin/players/:id/reset
//  - DELETE /admin/players/:id
//  - POST   /admin/players/:id/copy
//  - POST   /admin/players/:id/transfer
//

import Foundation
import Vapor
import Fluent

// MARK: - Admin Player Routes
extension AdminController {
    func setupPlayerRoutes(on root: RoutesBuilder) {
        let players = root.grouped("players")

        players.get(":id", use: getPlayerByID)
        players.get("sid", ":sid", use: getPlayerBySID)

        players.get(":id", "events", use: getPlayerByIDWithEvents)
        players.get(":id", "bundle", use: getPlayerByIDBundle)

        // multipart/form-data
        players.post("register", use: registerPlayer)

        players.patch(":id", use: patchPlayer)

        players.post(":id", "reset", use: resetPlayer)
        players.delete(":id", use: deletePlayer)

        players.post(":id", "copy", use: copyPlayer)
        players.post(":id", "transfer", use: transferPlayer)
        players.post("search", use: searchPlayersCompact) // POST /admin/players/search
        players.get(use: getAllPlayersCompact)            // GET  /admin/players
        players.post(":id", "identification", use: uploadPlayerIdentification)
        players.post(":id", "image", use: uploadPlayerImage)

    }
    
}

// MARK: - DTOs
extension AdminController {
    
    struct UploadPlayerIdentificationRequest: Content {
            let identificationImage: File
        }

        struct UploadPlayerImageRequest: Content {
            let playerImage: File
        }
    
    struct AdminPlayerBundleResponse: Content {
        let player: Player
        let team: AdminTeamOverview?
        let events: [MatchEvent]
        let transfers: [Transfer]
    }

    struct AdminPlayerWithEventsResponse: Content {
        let player: Player
        let events: [MatchEvent]
    }

    struct AdminTransferPlayerRequest: Content {
        let toTeamId: UUID
    }

    struct AdminCopyPlayerRequest: Content {
        let toTeamId: UUID
        let newSid: String?
    }

    /// multipart/form-data
    /// NOTE: `playerImage` is required, `identificationImage` optional.
    struct AdminRegisterPlayerRequest: Content {
        let teamID: UUID

        let sid: String?
        let name: String
        let number: String
        let birthday: String
        let nationality: String
        let position: String
        let email: String?

        let eligibility: PlayerEligibility?
        let registerDate: String?

        let playerImage: File
        let identificationImage: File?
    }

    struct PatchPlayerRequest: Content {
        let sid: String?

        let teamId: UUID?

        let image: String?
        let email: String?
        let balance: Double?

        let name: String?
        let number: String?
        let birthday: String?
        let nationality: String?
        let position: String?
        let eligibility: PlayerEligibility?
        let registerDate: String?

        let identification: String?
        let status: Bool?
        let isCaptain: Bool?
        let bank: Bool?
        let transferred: Bool?
        let blockdate: Date?
        let team_oeid: String?
    }
}

// MARK: - Handlers
extension AdminController {

    // GET /admin/players/:id
    func getPlayerByID(req: Request) async throws -> Player {
        let playerId = try req.parameters.require("id", as: UUID.self)
        guard let player = try await Player.find(playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }
        return player
    }

    // GET /admin/players/sid/:sid
    func getPlayerBySID(req: Request) async throws -> Player {
        let sid = try req.parameters.require("sid")
        guard let player = try await Player.query(on: req.db)
            .filter(\.$sid == sid)
            .first()
        else {
            throw Abort(.notFound, reason: "Player not found.")
        }
        return player
    }

    // GET /admin/players/:id/events
    func getPlayerByIDWithEvents(req: Request) async throws -> AdminPlayerWithEventsResponse {
        let playerId = try req.parameters.require("id", as: UUID.self)

        guard let player = try await Player.query(on: req.db)
            .filter(\.$id == playerId)
            .with(\.$events)
            .first()
        else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        return AdminPlayerWithEventsResponse(player: player, events: player.events)
    }

    // POST /admin/players/register (multipart/form-data)
    func registerPlayer(req: Request) async throws -> Player {
        let payload = try req.content.decode(AdminRegisterPlayerRequest.self)

        guard payload.playerImage.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "playerImage is required.")
        }

        // validate team exists
        guard let team = try await Team.find(payload.teamID, on: req.db) else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        let sid = (payload.sid?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? generateSixDigitSID()

        // upload images
        let firebase = req.application.firebaseManager
        try await firebase.authenticate().get()

        let basePath = "players/\(sid)"
        let playerImageURL = try await firebase
            .uploadFile(file: payload.playerImage, to: "\(basePath)/player_image")
            .get()

        var identificationURL: String? = nil
        if let idFile = payload.identificationImage, idFile.data.readableBytes > 0 {
            identificationURL = try await firebase
                .uploadFile(file: idFile, to: "\(basePath)/player_identification")
                .get()
        }

        let player = Player(
            id: nil,
            sid: sid,
            image: playerImageURL,
            team_oeid: nil,
            email: payload.email,
            balance: nil,
            name: payload.name,
            number: payload.number,
            birthday: payload.birthday,
            teamID: try team.requireID(),
            nationality: payload.nationality,
            position: payload.position,
            eligibility: payload.eligibility ?? .Warten,
            registerDate: payload.registerDate ?? currentRegisterDateString(),
            identification: identificationURL,
            status: true,
            isCaptain: false,
            bank: true,
            blockdate: nil
        )

        try await player.save(on: req.db)
        return player
    }

    // PATCH /admin/players/:id
    func patchPlayer(req: Request) async throws -> Player {
        let playerId = try req.parameters.require("id", as: UUID.self)
        let patch = try req.content.decode(PatchPlayerRequest.self)

        guard let player = try await Player.find(playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        if let sid = patch.sid { player.sid = sid }
        if let teamId = patch.teamId { player.$team.id = teamId }

        if let image = patch.image { player.image = image }
        if let email = patch.email { player.email = email }
        if let balance = patch.balance { player.balance = balance }

        if let name = patch.name {
            player.name = name
            player.nameLower = name.lowercased()
        }
        if let number = patch.number { player.number = number }
        if let birthday = patch.birthday { player.birthday = birthday }
        if let nationality = patch.nationality { player.nationality = nationality }
        if let position = patch.position { player.position = position }
        if let eligibility = patch.eligibility { player.eligibility = eligibility }
        if let registerDate = patch.registerDate { player.registerDate = registerDate }

        if let identification = patch.identification { player.identification = identification }
        if let status = patch.status { player.status = status }
        if let isCaptain = patch.isCaptain { player.isCaptain = isCaptain }
        if let bank = patch.bank { player.bank = bank }
        if let transferred = patch.transferred { player.transferred = transferred }
        if let blockdate = patch.blockdate { player.blockdate = blockdate }
        if let team_oeid = patch.team_oeid { player.team_oeid = team_oeid }

        try await player.save(on: req.db)
        return player
    }

    // POST /admin/players/:id/reset
    func resetPlayer(req: Request) async throws -> HTTPStatus {
        let playerId = try req.parameters.require("id", as: UUID.self)

        guard let player = try await Player.find(playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        // "reset" = back to pending
        player.eligibility = .Warten
        player.image = ""
        player.identification = ""
        player.nameLower = player.name.lowercased()

        try await player.save(on: req.db)
        return .ok
    }

    // DELETE /admin/players/:id
    func deletePlayer(req: Request) async throws -> HTTPStatus {
        let playerId = try req.parameters.require("id", as: UUID.self)

        guard let player = try await Player.find(playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        try await player.delete(on: req.db)
        return .ok
    }

    // POST /admin/players/:id/transfer
    func transferPlayer(req: Request) async throws -> HTTPStatus {
        let playerId = try req.parameters.require("id", as: UUID.self)
        let body = try req.content.decode(AdminTransferPlayerRequest.self)

        guard let player = try await Player.find(playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }
        guard let _ = try await Team.find(body.toTeamId, on: req.db) else {
            throw Abort(.notFound, reason: "Destination team not found.")
        }

        player.$team.id = body.toTeamId
        player.transferred = true
        player.nameLower = player.name.lowercased()

        try await player.save(on: req.db)
        return .ok
    }

    // POST /admin/players/:id/copy
    func copyPlayer(req: Request) async throws -> Player {
        let playerId = try req.parameters.require("id", as: UUID.self)
        let body = try req.content.decode(AdminCopyPlayerRequest.self)

        guard let original = try await Player.find(playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }
        guard let _ = try await Team.find(body.toTeamId, on: req.db) else {
            throw Abort(.notFound, reason: "Destination team not found.")
        }

        let copy = Player()
        _ = copy.merge(from: original)

        copy.id = nil
        copy.$team.id = body.toTeamId
        if let newSid = body.newSid?.trimmingCharacters(in: .whitespacesAndNewlines), !newSid.isEmpty {
            copy.sid = newSid
        }
        copy.nameLower = copy.name.lowercased()

        try await copy.save(on: req.db)
        return copy
    }
    
    func getPlayerByIDBundle(req: Request) async throws -> AdminPlayerBundleResponse {
           let playerId = try req.parameters.require("id", as: UUID.self)

           guard let player = try await Player.query(on: req.db)
               .filter(\.$id == playerId)
               .with(\.$events)
               .with(\.$team) // ✅ load team
               .first()
           else {
               throw Abort(.notFound, reason: "Player not found.")
           }

           let transfers = try await Transfer.query(on: req.db)
               .filter(\.$player == playerId)
               .sort(\.$created, .descending)
               .all()

           // ✅ Map Team -> AdminTeamOverview
           let teamOverview: AdminTeamOverview? = try player.team.map { t in
               AdminTeamOverview(
                   id: try t.requireID(),
                   sid: t.sid ?? "",
                   league: t.$league.id,
                   points: t.points,          // Team.points is non-optional in your model
                   logo: t.logo,
                   name: t.teamName,
                   shortName: t.shortName
               )
           }

           return AdminPlayerBundleResponse(
               player: player,
               team: teamOverview,
               events: player.events,
               transfers: transfers
           )
       }
    
    
}

extension AdminController {
    
    struct SearchPlayersRequest: Content {
        let term: String
    }
    
    // POST /admin/players/search
    // Body: { "term": "..." }
    func searchPlayersCompact(req: Request) async throws -> [AdminPlayerCompact] {
        let body = try req.content.decode(SearchPlayersRequest.self)
        let term = body.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw Abort(.badRequest, reason: "term is required.") }
        
        let lower = term.lowercased()
        
        let players = try await Player.query(on: req.db)
            .group(.or) { or in
                // SID "contains"
                or.filter(\.$sid ~~ term)
                
                // nameLower contains (preferred)
                or.filter(\.$nameLower ~~ lower)
                
                // fallback name contains (if nameLower missing/empty)
                or.filter(\.$name ~~ term)
            }
            .sort(\.$name, .ascending)
            .all()
        
        return try players.map { p in
            AdminPlayerCompact(
                id: try p.requireID(),
                sid: p.sid,
                name: p.name,
                image: p.image,
                eligibility: p.eligibility,
                nationality: p.nationality
            )
        }
    }
    
    struct PaginationQuery: Content {
        let page: Int?
        let pageSize: Int?
    }
    
    struct PaginatedResponse<T: Content>: Content {
        let items: [T]
        let page: Int
        let pageSize: Int
        let total: Int
    }
    
    // GET /admin/players
    func getAllPlayersCompact(req: Request) async throws -> PaginatedResponse<AdminPlayerCompact> {
        let q = try req.query.decode(PaginationQuery.self)
        
        let page = max(1, q.page ?? 1)
        let pageSizeRaw = q.pageSize ?? 50
        let pageSize = min(max(1, pageSizeRaw), 200) // clamp
        
        let total = try await Player.query(on: req.db).count()
        
        let players = try await Player.query(on: req.db)
            .sort(\.$name, .ascending)
            .range((page - 1) * pageSize ..< page * pageSize)
            .all()
        
        let items = try players.map { p in
            AdminPlayerCompact(
                id: try p.requireID(),
                sid: p.sid,
                name: p.name,
                image: p.image,
                eligibility: p.eligibility,
                nationality: p.nationality
            )
        }
        
        return PaginatedResponse(items: items, page: page, pageSize: pageSize, total: total)
    }
}

extension AdminController {

    // POST /admin/players/:id/identification  (multipart/form-data)
    func uploadPlayerIdentification(req: Request) async throws -> Player {
        let playerId = try req.parameters.require("id", as: UUID.self)
        let payload = try req.content.decode(UploadPlayerIdentificationRequest.self)

        guard payload.identificationImage.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "identificationImage file is required.")
        }

        guard let player = try await Player.find(playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        let firebaseManager = req.application.firebaseManager

        // Upload path based on SID (same as registration style)
        let basePath = "players/\(player.sid)"
        let identificationImagePath = "\(basePath)/player_identification"

        try await firebaseManager.authenticate().get()
        let identificationURL = try await firebaseManager
            .uploadFile(file: payload.identificationImage, to: identificationImagePath)
            .get()

        player.identification = identificationURL
        try await player.save(on: req.db)
        return player
    }

    // POST /admin/players/:id/image  (multipart/form-data)
    func uploadPlayerImage(req: Request) async throws -> Player {
        let playerId = try req.parameters.require("id", as: UUID.self)
        let payload = try req.content.decode(UploadPlayerImageRequest.self)

        guard payload.playerImage.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "playerImage file is required.")
        }

        guard let player = try await Player.find(playerId, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        let firebaseManager = req.application.firebaseManager

        let basePath = "players/\(player.sid)"
        let playerImagePath = "\(basePath)/player_image"

        try await firebaseManager.authenticate().get()
        let imageURL = try await firebaseManager
            .uploadFile(file: payload.playerImage, to: playerImagePath)
            .get()

        player.image = imageURL
        try await player.save(on: req.db)
        return player
    }
}

// MARK: - small helpers
private func generateSixDigitSID() -> String {
    String(Int.random(in: 100_000..<1_000_000))
}

private func currentRegisterDateString() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "Europe/Vienna")
    return f.string(from: Date())
}
