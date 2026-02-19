//
//  AdminController+TeamRoutes.swift
//
//  Purpose:
//  - Keep AdminController small by splitting per model into extensions.
//  - Mirror the structure of AdminController+LeagueRoutes.swift:
//      - setupXRoutes
//      - DTOs
//      - handlers
//      - helpers
//
//  Assumptions:
//  - Mounted under AdminController authed + AdminOnlyMiddleware() group
//  - Team and Player conform to Mergeable (true in your code)
//  - Player has parent relation to Team via \.$team
//

import Foundation
import Vapor
import Fluent

// MARK: - Admin Team Routes
extension AdminController {

    /// Mount all team-related admin endpoints under:
    ///   /admin/teams/...
    ///
    /// Naming convention:
    /// - “search” endpoints return overview models (small payload).
    /// - “detail” endpoints return full models (bigger payload).
    func setupTeamRoutes(on root: RoutesBuilder) {
        let teams = root.grouped("teams")

        // MARK: Detail
        // GET /admin/teams/:id
        // -> Returns Team + Players.
        teams.get(":id", use: getTeamByIDWithPlayers)

        // GET /admin/teams/:id/rechnungen
        // -> Returns all Rechnungen for a team.
        teams.get(":id", "rechnungen", use: getTeamRechnungen)

        // MARK: Search
        // GET /admin/teams/search?q=...&id=...&sid=...&leagueId=...
        // -> Finds teams by name/id/sid.
        teams.post("search", use: searchTeams)

        // MARK: Mutations
        // PATCH /admin/teams/:id
        // -> Patch-style update using Mergeable.
        teams.patch(":id", use: patchTeam)

        // POST /admin/teams/:id/topup
        // -> Add amount to team balance.
        teams.post(":id", "topup", use: topupAccount)

        // POST /admin/teams/:fromTeamId/players/:playerId/copy
        // -> Duplicate a player onto another team (original stays).
        teams.post(":id", "players", ":playerId", "copy", use: copyPlayerToAnotherTeam)
        teams.post(":id", "players", "copy", use: copyPlayersBatch)

        // POST /admin/teams/:fromTeamId/players/:playerId/transfer
        // -> Move a player to another team (original moves).
        teams.post(":id", "players", ":playerId", "transfer", use: transferPlayerToAnotherTeam)
        teams.post(":id", "players", "transfer", use: transferPlayersBatch)

        // GET /admin/teams
        // -> Returns ALL teams as AppTeamOverview[] (overview only).
        teams.get(use: getAllTeamsOverview)
        
        // MARK: Slim index (fast list for filtering)
        teams.get("index", use: getTeamsSlimIndex)

        // MARK: Detail bundle (team + compact players + rechnungen)
        teams.get(":id", "detail", use: getTeamDetailBundle)

        // MARK: Manual player creation (multipart + optional image upload)
        teams.post(":id", "players", "manual", use: createPlayerManual)
        teams.post(":id", "rechnungen", ":rechnungId", "refund", use: refundRechnung)

        
        teams.post(":id", "logo", use: uploadTeamLogo)
        teams.post(":id", "cover", use: uploadTeamCoverImage)

        
    }
}

// MARK: - DTOs (Query / Request / Response)
extension AdminController {
    
    struct UploadTeamLogoRequest: Content {
        let logo: File
    }

    struct UploadTeamCoverRequest: Content {
        let coverimg: File
    }

    
    struct RefundRechnungResponse: Content {
        let teamId: UUID
        let newBalance: Double
        let refundRechnung: Rechnung
    }

    /// Slim index row for fast filtering/listing
    struct AdminTeamIndexItem: Content {
        let id: UUID
        let teamName: String
        let logo: String
        let leagueId: UUID?
        let leagueName: String?
        let balance: Double?
    }

    /// Compact player row for admin table
    struct AdminPlayerCompact: Content {
        let id: UUID
        let sid: String
        let name: String
        let image: String?
        let eligibility: PlayerEligibility
        let nationality: String
    }

    /// Detail bundle response
    struct AdminTeamDetailBundle: Content {
        let team: Team
        let players: [AdminPlayerCompact]
        let rechnungen: [Rechnung]
    }

    /// Manual player creation (multipart/form-data)
    struct CreatePlayerManualRequest: Content {
        let sid: String
        let name: String
        let number: String
        let birthday: String
        let nationality: String
        let position: String
        let eligibility: PlayerEligibility
        let registerDate: String

        let email: String?
        let image: File?
    }

    /// Query model for GET /admin/teams/search
    ///
    /// Rules:
    /// - If multiple filters are present, they are combined.
    /// - q is treated as “contains” on name fields.
    struct SearchTeamsQuery: Content {
        let q: String?
        let sid: String?
    }

    /// Patch request for Team.
    /// We keep it “optional fields only” so clients can send partial updates.
    struct PatchTeamRequest: Content {
        let teamName: String?
        let shortName: String?
        let logo: String?
        let coverimg: String?

        let coach: Trainer?
        let altCoach: Trainer?
        let captain: String?

        let trikot: Trikot?

        let points: Int?
        let cancelled: Int?
        let postponed: Int?

        let overdraft: Bool?
        let overdraftDate: Date?

        let leagueId: UUID?
        let leagueCode: String?

        let balance: Double?
        let referCode: String?
    }

    /// Top up / add money to Team.balance.
    /// This keeps money changes explicit and separate from PATCH.
    struct TopupRequest: Content {
        let amount: Double
        let note: String?
    }

    /// Detail response for team page: Team + all players.
    struct TeamWithPlayersResponse: Content {
        let team: Team
        let players: [Player]
    }
    
    struct AdminTeamOverview: Content, Codable {
        let id: UUID
        let sid: String
        let league: UUID?
        let points: Int
        let logo: String
        let name: String
        let shortName: String?
        
    }
    
    /// Body for copy/transfer operations.
    /// - toTeamId: destination team
    /// - playerIds: for batch operations (optional)
    struct MovePlayerRequest: Content {
        let toTeamId: UUID
        let playerIds: [UUID]?
    }
}

// MARK: - Handlers
extension AdminController {

    // MARK: GET /admin/teams/:id
    /// Returns the Team and its players in one response.
    /// Good for admin “team detail” screens.
    func getTeamByIDWithPlayers(req: Request) async throws -> TeamWithPlayersResponse {
        let team = try await requireTeam(req: req, param: "id")
        let teamId = try team.requireID()

        // Explicit children query (predictable, avoids relying on implicit encoding).
        let players = try await Player.query(on: req.db)
            .filter(\.$team.$id == teamId)
            .sort(\.$name, .ascending)
            .all()

        return TeamWithPlayersResponse(team: team, players: players)
    }

    // MARK: GET /admin/teams/search
    /// Search teams by:
    /// - UUID id (exact)
    /// - sid (exact)
    /// - q (contains) on teamNameLower / teamName / shortName
    ///
    /// Returns AppTeamOverview (small payload).
    func searchTeams(req: Request) async throws -> [AdminTeamOverview] {
        let query = try req.content.decode(SearchTeamsQuery.self)

        // Normalize inputs
        let sid = query.sid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query.q?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Require at least one filter so we don’t accidentally return “all teams”
        guard (sid?.isEmpty == false) || (q?.isEmpty == false) else {
            throw Abort(.badRequest, reason: "Provide either `sid` or `q`.")
        }

        var qb = Team.query(on: req.db)

        // Prefer SID if provided (exact lookup)
        if let sid, !sid.isEmpty {
            qb = qb.filter(\.$sid == sid)
        }

        // Name search (contains)
        if let q, !q.isEmpty {
            let qLower = q.lowercased()
            qb = qb.group(.or) { or in
                // Preferred (your model has teamNameLower)
                or.filter(\.$teamNameLower ~~ qLower)

                // Fallbacks
                or.filter(\.$teamName ~~ q)
                or.filter(\.$shortName ~~ q)
            }
        }


        let teams = try await qb
            .sort(\.$teamName, .ascending)
            .all()

        return try teams.map { team in
            AdminTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: team.$league.id,
                points: team.points ?? 0,
                logo: team.logo ?? "",
                name: team.teamName,
                shortName: team.shortName
            )
        }
    }



    // MARK: PATCH /admin/teams/:id
    /// Patch Team using Mergeable.
    ///
    /// Pattern:
    /// 1) Fetch Team
    /// 2) Build a “patch Team” that only fills changed fields
    /// 3) team.merge(from: patchTeam)
    /// 4) Save
    ///
    /// Why do it this way?
    /// - Keeps all “how to overwrite fields” inside Team.merge(from:)
    /// - Handler only validates and constructs the patch object.
    func patchTeam(req: Request) async throws -> Team {
        let team = try await requireTeam(req: req, param: "id")
        let patch = try req.content.decode(PatchTeamRequest.self)

        // Validate name if present.
        var trimmedTeamName: String? = nil
        if let name = patch.teamName {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "teamName cannot be empty.")
            }
            trimmedTeamName = trimmed
        }

        // Build a patch Team object:
        // IMPORTANT:
        // - We must provide required init args. If your init has many required params,
        //   we can reuse existing values and only swap the updated ones.
        //
        // This approach keeps everything consistent + future-proof.
        let patchTeam = Team(
            id: team.id,
            sid: team.sid ?? "",
            userId: team.$user.id,
            leagueId: patch.leagueId ?? team.$league.id,
            leagueCode: patch.leagueCode ?? team.leagueCode,
            points: patch.points ?? team.points,
            coverimg: patch.coverimg ?? (team.coverimg ?? ""),
            logo: patch.logo ?? team.logo,
            teamName: trimmedTeamName ?? team.teamName,
            shortName: patch.shortName ?? team.shortName,
            foundationYear: team.foundationYear,
            membershipSince: team.membershipSince,
            averageAge: team.averageAge,
            coach: patch.coach ?? team.coach,
            altCoach: patch.altCoach ?? team.altCoach,
            captain: patch.captain ?? team.captain,
            trikot: patch.trikot ?? team.trikot,
            balance: patch.balance ?? team.balance,
            referCode: patch.referCode ?? team.referCode,
            overdraft: patch.overdraft ?? team.overdraft,
            cancelled: patch.cancelled ?? team.cancelled,
            postponed: patch.postponed ?? team.postponed,
            overdraftDate: patch.overdraftDate ?? team.overdraftDate,
            usremail: team.usremail,
            usrpass: team.usrpass,
            usrtel: team.usrtel,
            kaution: team.kaution
        )

        // Merge and keep derived fields consistent.
        _ = team.merge(from: patchTeam)
        if let n = trimmedTeamName {
            team.teamNameLower = n.lowercased()
        }

        try await team.save(on: req.db)
        return team
    }

    // MARK: POST /admin/teams/:id/topup
    /// Adds a positive amount to Team.balance AND creates a Rechnung.
    ///
    /// Rechnung fields:
    /// - number: "YYYY-#####"
    /// - kennzeichen: "dd.MM.yyyy Guthaben Einzahlung" (+ optional note)
    /// - summ: amount
    /// - topay: nil (Rechnung init defaults topay to summ)
    func topupAccount(req: Request) async throws -> HTTPStatus {
        let team = try await requireTeam(req: req, param: "id")
        let teamId = try team.requireID()
        let body = try req.content.decode(TopupRequest.self)

        guard body.amount > 0 else {
            throw Abort(.badRequest, reason: "amount must be > 0.")
        }

        let currentYear = Calendar.current.component(.year, from: Date.viennaNow)
        let randomNumber = String.randomNum(length: 5)
        let number = "\(currentYear)-\(randomNumber)"

        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        let currentDate = df.string(from: Date.viennaNow)

        let note = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteSuffix = (note?.isEmpty == false) ? " - \(note!)" : ""
        let kennzeichen = "\(currentDate) Guthaben Einzahlung\(noteSuffix)"

        let rechnung = Rechnung(
            team: teamId,
            teamName: team.teamName,
            status: .offen,
            number: number,
            summ: body.amount,
            topay: nil,
            previousBalance: team.balance,
            kennzeichen: kennzeichen,
            created: Date.viennaNow
        )

        team.balance = (team.balance ?? 0) + body.amount

        // ✅ Works on Mongo standalone
        try await team.save(on: req.db)
        try await rechnung.create(on: req.db)

        return .ok
    }


    // MARK: POST /admin/teams/:fromTeamId/players/:playerId/copy
    /// Copies a player into another team by:
    /// - creating a new Player instance
    /// - merging all data from source player (Mergeable)
    /// - overriding the team id
    /// - saving
    ///
    /// Important: the original player remains untouched.
    func copyPlayerToAnotherTeam(req: Request) async throws -> HTTPStatus {
        let fromTeam = try await requireTeam(req: req, param: "id")

        let fromTeamId = try fromTeam.requireID()

        let sourcePlayer = try await requirePlayer(req: req, param: "playerId")

        guard sourcePlayer.$team.id == fromTeamId else {
            throw Abort(.badRequest, reason: "Player does not belong to fromTeamId.")
        }

        let body = try req.content.decode(MovePlayerRequest.self)
        let toTeam = try await requireTeamByID(body.toTeamId, db: req.db)
        let toTeamId = try toTeam.requireID()

        // Create a new player and merge all fields from source.
        // Merge includes IDs; we explicitly clear the ID so this becomes a new record.
        let copied = Player()
        _ = copied.merge(from: sourcePlayer)
        copied.id = nil

        // Attach to the target team.
        copied.$team.id = toTeamId

        // Keep derived field consistent.
        copied.nameLower = copied.name.lowercased()

        try await copied.save(on: req.db)
        return .ok
    }

    // MARK: POST /admin/teams/:fromTeamId/players/:playerId/transfer
    /// Transfers (moves) a player from one team to another by updating `player.$team.id`.
    func transferPlayerToAnotherTeam(req: Request) async throws -> HTTPStatus {
        let fromTeam = try await requireTeam(req: req, param: "id")

        let fromTeamId = try fromTeam.requireID()

        let player = try await requirePlayer(req: req, param: "playerId")

        guard player.$team.id == fromTeamId else {
            throw Abort(.badRequest, reason: "Player does not belong to fromTeamId.")
        }

        let body = try req.content.decode(MovePlayerRequest.self)
        let toTeam = try await requireTeamByID(body.toTeamId, db: req.db)
        let toTeamId = try toTeam.requireID()

        player.$team.id = toTeamId
        player.transferred = true // optional: you already have field
        try await player.save(on: req.db)

        return .ok
    }

    // MARK: GET /admin/teams/:id/rechnungen
    /// Fetch all invoices belonging to a team.
    func getTeamRechnungen(req: Request) async throws -> [Rechnung] {
        let team = try await requireTeam(req: req, param: "id")
        let teamId = try team.requireID()

        return try await Rechnung.query(on: req.db)
            .filter(\.$team.$id == teamId)
            .sort(\.$created, .descending)
            .all()
    }
    
    // MARK: GET /admin/teams
    /// Returns ALL teams as AdminTeamOverview (small payload).
    /// Useful for admin dropdowns, global lists, etc.
    func getAllTeamsOverview(req: Request) async throws -> [AdminTeamOverview] {
        let teams = try await Team.query(on: req.db)
            .sort(\.$teamName, .ascending)
            .all()

        return try teams.map { team in
            AdminTeamOverview(
                id: try team.requireID(),
                sid: team.sid ?? "",
                league: team.$league.id,
                points: team.points ?? 0,
                logo: team.logo ?? "",
                name: team.teamName,
                shortName: team.shortName
            )
        }
    }
    
    func getTeamsSlimIndex(req: Request) async throws -> [AdminTeamIndexItem] {
        let teams = try await Team.query(on: req.db)
            .with(\.$league)
            .sort(\.$teamName, .ascending)
            .all()

        return try teams.map { t in
            AdminTeamIndexItem(
                id: try t.requireID(),
                teamName: t.teamName,
                logo: t.logo,
                leagueId: t.$league.id,
                leagueName: t.league?.name,
                balance: t.balance
            )
        }
    }

    func getTeamDetailBundle(req: Request) async throws -> AdminTeamDetailBundle {
        let team = try await requireTeam(req: req, param: "id")
        let teamId = try team.requireID()

        let players = try await Player.query(on: req.db)
            .filter(\.$team.$id == teamId)
            .sort(\.$name, .ascending)
            .all()

        let compactPlayers: [AdminPlayerCompact] = try players.map { p in
            AdminPlayerCompact(
                id: try p.requireID(),
                sid: p.sid,
                name: p.name,
                image: p.image,
                eligibility: p.eligibility,
                nationality: p.nationality
            )
        }

        let rechnungen = try await Rechnung.query(on: req.db)
            .filter(\.$team.$id == teamId)
            .sort(\.$created, .descending)
            .all()

        return AdminTeamDetailBundle(team: team, players: compactPlayers, rechnungen: rechnungen)
    }

    func createPlayerManual(req: Request) async throws -> Player {
        let team = try await requireTeam(req: req, param: "id")
        let teamId = try team.requireID()

        let body = try req.content.decode(CreatePlayerManualRequest.self)

        let sid = body.sid.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sid.isEmpty else { throw Abort(.badRequest, reason: "sid is required.") }
        guard !name.isEmpty else { throw Abort(.badRequest, reason: "name is required.") }

        // Optional upload
        var finalImageURL: String? = nil
        if let imageFile = body.image, imageFile.data.readableBytes > 0 {
            // If you already have firebaseManager available globally like in AppController
            let firebaseManager = req.application.firebaseManager
            try await firebaseManager.authenticate().get()

            let path = "players/\(teamId.uuidString)/\(sid)/image"
            finalImageURL = try await firebaseManager.uploadFile(file: imageFile, to: path).get()
        }

        // Create player without depending on a huge initializer
        let player = Player()
        player.sid = sid
        player.name = name
        player.nameLower = name.lowercased()
        player.number = body.number
        player.birthday = body.birthday
        player.nationality = body.nationality
        player.position = body.position
        player.eligibility = body.eligibility
        player.registerDate = body.registerDate
        player.email = body.email
        player.image = finalImageURL

        player.$team.id = teamId

        // sensible defaults (if these exist on your model)
        player.status = true
        player.isCaptain = false
        player.bank = false
        player.transferred = false

        try await player.save(on: req.db)
        return player
    }


}

// MARK: - Helpers
private extension AdminController {

    /// Reads a UUID parameter and returns the Team.
    func requireTeam(req: Request, param: String) async throws -> Team {
        guard let id = req.parameters.get(param, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid team ID.")
        }
        return try await requireTeamByID(id, db: req.db)
    }

    func requireTeamByID(_ id: UUID, db: Database) async throws -> Team {
        guard let team = try await Team.find(id, on: db) else {
            throw Abort(.notFound, reason: "Team not found.")
        }
        return team
    }

    func requirePlayer(req: Request, param: String) async throws -> Player {
        guard let id = req.parameters.get(param, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid player ID.")
        }
        guard let player = try await Player.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }
        return player
    }

    /// Used to build AppTeamOverview, which expects a league overview.
    func requireLeagueForTeam(_ team: Team, db: Database) async throws -> League {
        guard let leagueId = team.$league.id else {
            throw Abort(.badRequest, reason: "Team has no league.")
        }
        guard let league = try await League.find(leagueId, on: db) else {
            throw Abort(.notFound, reason: "League not found.")
        }
        return league
    }
}

// MARK: - Handlers
extension AdminController {

    func refundRechnung(req: Request) async throws -> RefundRechnungResponse {
        let team = try await requireTeam(req: req, param: "id")
        let teamId = try team.requireID()

        guard let rechnungId = req.parameters.get("rechnungId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid rechnungId.")
        }

        guard let original = try await Rechnung.find(rechnungId, on: req.db) else {
            throw Abort(.notFound, reason: "Rechnung not found.")
        }

        guard original.$team.id == teamId else {
            throw Abort(.badRequest, reason: "Rechnung does not belong to this team.")
        }

        let refundDelta = -original.summ
        team.balance = (team.balance ?? 0) + refundDelta

        let currentYear = Calendar.current.component(.year, from: Date.viennaNow)
        let randomNumber = String.randomNum(length: 5)
        let number = "\(currentYear)-\(randomNumber)"

        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        let currentDate = df.string(from: Date.viennaNow)

        let refund = Rechnung(
            team: teamId,
            teamName: team.teamName,
            status: .bezahlt,
            number: number,
            summ: refundDelta,
            topay: 0,
            previousBalance: team.balance,
            kennzeichen: "\(currentDate) Refund für Rechnung \(original.number) - \(original.kennzeichen)",
            created: Date.viennaNow
        )

        // Mongo standalone friendly: sequential writes
        try await team.save(on: req.db)
        try await refund.create(on: req.db)
        try await original.delete(on: req.db)   // ✅ delete original

        return RefundRechnungResponse(
            teamId: teamId,
            newBalance: team.balance ?? 0,
            refundRechnung: refund
        )
    }
}

// MARK: - Batch handlers
extension AdminController {

    /// POST /admin/teams/:id/players/copy
    /// Body: { "toTeamId": "UUID", "playerIds": ["UUID", ...] }
    ///
    /// Copies multiple players from team :id to toTeamId.
    /// - Creates NEW player records (keeps originals)
    /// - Uses Mergeable to copy fields, but clears `id` to force inserts
    /// - Keeps derived fields consistent (nameLower)
    func copyPlayersBatch(req: Request) async throws -> HTTPStatus {
        let fromTeam = try await requireTeam(req: req, param: "id")
        let fromTeamId = try fromTeam.requireID()

        let body = try req.content.decode(MovePlayerRequest.self)
        let toTeamId = body.toTeamId

        guard let playerIds = body.playerIds, !playerIds.isEmpty else {
            throw Abort(.badRequest, reason: "playerIds is required for batch copy.")
        }

        _ = try await requireTeamByID(toTeamId, db: req.db) // validate destination exists

        let players = try await requirePlayers(playerIds, belongTo: fromTeamId, db: req.db)

        // Create all copies in memory first
        let copies: [Player] = players.map { original in
            let copied = Player()
            _ = copied.merge(from: original)
            copied.id = nil
            copied.$team.id = toTeamId
            copied.nameLower = copied.name.lowercased()
            copied.transferred = original.transferred
            return copied
        }

        // Save sequentially (Mongo standalone friendly; no transactions)
        for p in copies {
            try await p.save(on: req.db)
        }

        return .ok
    }

    /// POST /admin/teams/:id/players/transfer
    /// Body: { "toTeamId": "UUID", "playerIds": ["UUID", ...] }
    ///
    /// Transfers multiple players from team :id to toTeamId.
    /// - Updates existing players' team id
    /// - Sets `transferred = true`
    func transferPlayersBatch(req: Request) async throws -> HTTPStatus {
        let fromTeam = try await requireTeam(req: req, param: "id")
        let fromTeamId = try fromTeam.requireID()

        let body = try req.content.decode(MovePlayerRequest.self)
        let toTeamId = body.toTeamId

        guard let playerIds = body.playerIds, !playerIds.isEmpty else {
            throw Abort(.badRequest, reason: "playerIds is required for batch transfer.")
        }

        _ = try await requireTeamByID(toTeamId, db: req.db) // validate destination exists

        let players = try await requirePlayers(playerIds, belongTo: fromTeamId, db: req.db)

        for player in players {
            player.$team.id = toTeamId
            player.transferred = true
            // keep derived field consistent if you rely on it for searching
            player.nameLower = player.name.lowercased()
            try await player.save(on: req.db)
        }

        return .ok
    }
}

// MARK: - File Upload
extension AdminController {

    // POST /admin/teams/:id/logo (multipart/form-data)
    func uploadTeamLogo(req: Request) async throws -> Team {
        let team = try await requireTeam(req: req, param: "id")
        _ = try team.requireID()

        let body = try req.content.decode(UploadTeamLogoRequest.self)
        guard body.logo.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "logo file is required.")
        }

        let firebaseManager = req.application.firebaseManager
        try await firebaseManager.authenticate().get()

        // Use teamId for stable path
        let teamId = try team.requireID()
        let path = "teams/\(teamId.uuidString)/logo"

        let url = try await firebaseManager.uploadFile(file: body.logo, to: path).get()

        team.logo = url
        try await team.save(on: req.db)
        return team
    }

    // POST /admin/teams/:id/cover (multipart/form-data)
    func uploadTeamCoverImage(req: Request) async throws -> Team {
        let team = try await requireTeam(req: req, param: "id")
        _ = try team.requireID()

        let body = try req.content.decode(UploadTeamCoverRequest.self)
        guard body.coverimg.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "coverimg file is required.")
        }

        let firebaseManager = req.application.firebaseManager
        try await firebaseManager.authenticate().get()

        let teamId = try team.requireID()
        let path = "teams/\(teamId.uuidString)/coverimg"

        let url = try await firebaseManager.uploadFile(file: body.coverimg, to: path).get()

        team.coverimg = url
        try await team.save(on: req.db)
        return team
    }
}

// MARK: - Batch helpers
private extension AdminController {

    /// Loads all players in one query, validates they all exist, and all belong to `fromTeamId`.
    ///
    /// NOTE: we validate membership explicitly so batch requests can't accidentally move/copy
    /// players from other teams.
    func requirePlayers(_ ids: [UUID], belongTo fromTeamId: UUID, db: Database) async throws -> [Player] {
        // Load all players in one DB query
        let players = try await Player.query(on: db)
            .filter(\.$id ~~ ids)
            .all()

        // Ensure all requested IDs exist
        if players.count != ids.count {
            let found = Set(players.compactMap { $0.id })
            let missing = ids.filter { !found.contains($0) }
            throw Abort(.notFound, reason: "Player(s) not found: \(missing)")
        }

        // Ensure all belong to the source team
        let wrongTeam = players.filter { $0.$team.id != fromTeamId }
        if !wrongTeam.isEmpty {
            let wrongIds = wrongTeam.compactMap { $0.id }
            throw Abort(.badRequest, reason: "Some players do not belong to fromTeamId: \(wrongIds)")
        }

        return players
    }
}

// MARK: - Route registration snippet
//
// Add these TWO lines inside setupTeamRoutes(on:):
//
// teams.post(":id", "players", "copy", use: copyPlayersBatch)
// teams.post(":id", "players", "transfer", use: transferPlayersBatch)
