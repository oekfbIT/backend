import Fluent
import Vapor

struct TransferRequest: Content {
    let team: UUID
    let player: UUID
}

// The primary key reserves a player's place in a season even when two requests
// arrive before either transaction can see the other's transfer.
final class SeasonTransferReservation: Model {
    static let schema = "season_transfer_reservations"

    @ID(custom: .id, generatedBy: .user) var id: String?
    @Field(key: "transferID") var transferID: UUID

    init() {}

    init(seasonID: UUID, playerID: UUID, transferID: UUID) {
        id = Self.key(seasonID: seasonID, playerID: playerID)
        self.transferID = transferID
    }

    static func key(seasonID: UUID, playerID: UUID) -> String {
        "\(seasonID):\(playerID)"
    }
}

struct SeasonTransferRulesMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(SeasonTransferReservation.schema)
            .field(.id, .string, .identifier(auto: false))
            .field("transferID", .uuid, .required)
            .unique(on: "transferID")
            .create()
        try await database.schema(Transfer.schema).field("seasonID", .uuid).update()
        try await database.schema(Season.schema)
            .field("transferOpen", .bool)
            .field("yellowCardSuspensionEnabled", .bool)
            .update()

        try await database.schema(Player.schema)
            .field("yellowCardSuspensionSeasonID", .uuid)
            .field("yellowCardSuspensionUntil", .datetime)
            .update()

        let wasOpen = try await TransferSettings.query(on: database).first()?.isTransferOpen ?? false
        try await Season.query(on: database)
            .filter(\.$primary == true)
            .filter(\.$transferOpen == nil)
            .set(\.$transferOpen, to: wasOpen)
            .update()

        // Assign legacy records once so future primary-season switches cannot
        // reinterpret an old pending request as a request for the new season.
        for season in try await SeasonTransfers.activeSeasons(on: database).all() {
            try await season.syncDateRange(on: database)
            guard let leagueID = season.$league.id, let start = season.startDate else { continue }
            let previousEnd = try await Season.query(on: database)
                .filter(\.$league.$id == leagueID)
                .filter(\.$endDate < start)
                .sort(\.$endDate, .descending)
                .first()?.endDate
            let teamIDs = try await SeasonTransfers.teamIDs(in: season, on: database)
            guard !teamIDs.isEmpty else { continue }

            let history = Transfer.query(on: database)
                .filter(\.$seasonID == nil)
                .filter(\.$team ~~ Array(teamIDs))
                .filter(\.$origin ~~ Array(teamIDs))
            if let previousEnd {
                history.filter(\.$created > previousEnd)
            } else {
                history.filter(\.$created >= start)
            }
            try await history.set(\.$seasonID, to: season.requireID()).update()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(SeasonTransferReservation.schema).delete()
    }
}

enum SeasonTransfers {
    static func activeSeasons(on db: Database) -> QueryBuilder<Season> {
        Season.query(on: db).filter(\.$primary == true).filter(\.$league.$id != nil)
    }

    static func isOpen(on db: Database) async throws -> Bool {
        try await activeSeasons(on: db).filter(\.$transferOpen == true).first() != nil
    }

    static func setOpen(_ open: Bool, on db: Database) async throws {
        try await activeSeasons(on: db).set(\.$transferOpen, to: open).update()
    }

    static func primarySeason(for team: Team, on db: Database) async throws -> Season? {
        guard let leagueID = team.$league.id else { return nil }
        return try await activeSeasons(on: db).filter(\.$league.$id == leagueID).first()
    }

    static func season(for team: Team, on db: Database) async throws -> Season {
        guard let season = try await primarySeason(for: team, on: db) else {
            throw Abort(.conflict, reason: "Für diese Liga ist keine Hauptsaison festgelegt.")
        }
        return season
    }

    static func teamIDs(in season: Season, on db: Database) async throws -> Set<UUID> {
        guard let leagueID = season.$league.id else { return [] }
        let ids = try await Team.query(on: db).filter(\.$league.$id == leagueID).all(\.$id)
        return Set(ids.compactMap { $0 })
    }

    private static func usedPlayers(_ players: [UUID], in season: Season, on db: Database) async throws -> Set<UUID> {
        guard !players.isEmpty else { return [] }
        let ids = try await Transfer.query(on: db)
            .filter(\.$seasonID == season.requireID())
            .filter(\.$player ~~ players)
            .filter(\.$status ~~ [.warten, .angenommen])
            .all(\.$player)
        return Set(ids)
    }

    static func requireOpen(_ season: Season) throws {
        guard season.transferOpen == true else {
            throw Abort(.forbidden, reason: "Das Transferfenster dieser Saison ist geschlossen.")
        }
    }

    static func options(for target: Team, on db: Database) async throws -> [Player] {
        let season = try await season(for: target, on: db)
        try requireOpen(season)
        let teamIDs = try await self.teamIDs(in: season, on: db).subtracting([target.requireID()])
        guard !teamIDs.isEmpty else { return [] }
        let players = try await Player.query(on: db)
            .filter(\.$team.$id ~~ Array(teamIDs))
            .filter(\.$eligibility ~~ [.Gesperrt, .Spielberechtigt])
            .filter(\.$email != nil)
            .filter(\.$email != "")
            .sort(\.$name)
            .all()
        let used = try await usedPlayers(players.compactMap(\.id), in: season, on: db)
        return Array(players.filter { $0.id.map { !used.contains($0) } ?? false }.prefix(200))
    }

    static func search(_ players: [Player], on db: Database) async throws -> [Player] {
        let seasons = try await activeSeasons(on: db).filter(\.$transferOpen == true).all()
        guard !seasons.isEmpty else { throw Abort(.forbidden, reason: "Transfers are currently closed.") }
        var eligible = Set<UUID>()
        for season in seasons {
            let teamIDs = try await self.teamIDs(in: season, on: db)
            let ids = players.filter { $0.$team.id.map(teamIDs.contains) ?? false }.compactMap(\.id)
            let used = try await usedPlayers(ids, in: season, on: db)
            eligible.formUnion(Set(ids).subtracting(used))
        }
        return players.filter { $0.id.map(eligible.contains) ?? false }
    }

    static func create(playerID: UUID, targetID: UUID, req: Request, admin: Bool = false, database: Database? = nil, expectedOrigin: UUID? = nil) async throws -> Transfer {
        try await (database ?? req.db).transaction { db in
            guard let player = try await Player.find(playerID, on: db),
                  let originID = player.$team.id,
                  let origin = try await Team.find(originID, on: db),
                  let target = try await Team.find(targetID, on: db) else {
                throw Abort(.notFound, reason: "Spieler oder Mannschaft nicht gefunden.")
            }
            guard expectedOrigin == nil || expectedOrigin == originID else {
                throw Abort(.conflict, reason: "Der Spieler ist nicht mehr bei der ursprünglichen Mannschaft.")
            }
            guard originID != targetID else {
                throw Abort(.badRequest, reason: "Der Spieler ist bereits bei dieser Mannschaft.")
            }
            if !admin {
                try ApplicationAccess.authorize(team: target, req: req)
                guard let leagueID = origin.$league.id, leagueID == target.$league.id else {
                    throw Abort(.badRequest, reason: "Transfers sind nur innerhalb derselben Liga möglich.")
                }
            }

            let season: Season?
            if admin {
                if let leagueID = origin.$league.id, leagueID == target.$league.id {
                    season = try await activeSeasons(on: db).filter(\.$league.$id == leagueID).first()
                } else {
                    season = nil
                }
            } else {
                season = try await self.season(for: target, on: db)
            }
            if let season {
                if !admin { try requireOpen(season) }
                let used = try await usedPlayers([playerID], in: season, on: db)
                guard !used.contains(playerID) else {
                    throw Abort(.conflict, reason: "Für diesen Spieler besteht bereits ein Transfer in dieser Saison.")
                }
            }

            let transferID = UUID()
            let transfer = Transfer(
                id: transferID, team: targetID, player: playerID,
                status: admin ? .angenommen : .warten, playerName: player.name,
                playerImage: player.image ?? "", teamName: target.teamName, teamImage: target.logo,
                origin: originID, originName: origin.teamName, originImage: origin.logo
            )
            if let seasonID = season?.id {
                transfer.seasonID = seasonID
                try await SeasonTransferReservation(seasonID: seasonID, playerID: playerID, transferID: transferID)
                    .create(on: db)
            }
            try await transfer.create(on: db)
            if admin {
                player.$team.id = targetID
                try await player.update(on: db)
            }
            return transfer
        }
    }

    static func request(playerID: UUID, targetID: UUID, req: Request) async throws -> Transfer {
        let transfer = try await create(playerID: playerID, targetID: targetID, req: req)
        do {
            if let email = try await Player.find(playerID, on: req.db)?.email {
                _ = try EmailController().sendTransferRequest(req: req, recipient: email, transfer: transfer)
            }
        } catch {
            req.logger.warning("Failed to send transfer email: \(error)")
        }
        return transfer
    }

    static func withdraw(id: UUID, req: Request) async throws {
        _ = try await respond(id: id, accept: false, req: req, authorizeDestination: true)
    }

    static func respond(
        id: UUID, accept: Bool, req: Request, fromEmail: Bool = false
    ) async throws -> Transfer {
        try await respond(id: id, accept: accept, req: req, fromEmail: fromEmail, authorizeDestination: false)
    }

    private static func respond(
        id: UUID, accept: Bool, req: Request, fromEmail: Bool = false, authorizeDestination: Bool
    ) async throws -> Transfer {
        try await req.db.transaction { db in
            guard let transfer = try await Transfer.find(id, on: db) else { throw Abort(.notFound) }
            if !fromEmail {
                let participantID = authorizeDestination ? transfer.team : transfer.origin
                guard let participant = try await Team.find(participantID, on: db) else { throw Abort(.forbidden) }
                try ApplicationAccess.authorize(team: participant, req: req)
            }
            guard transfer.status == .warten else {
                throw Abort(.conflict, reason: "Die Anfrage ist bereits abgeschlossen.")
            }

            if accept {
                guard let originID = transfer.origin,
                      let player = try await Player.find(transfer.player, on: db),
                      player.$team.id == originID,
                      let origin = try await Team.find(originID, on: db),
                      let target = try await Team.find(transfer.team, on: db),
                      let leagueID = origin.$league.id, leagueID == target.$league.id else {
                    throw Abort(.conflict, reason: "Die Mannschaften des Transfers stimmen nicht mehr überein.")
                }
                let season = try await season(for: target, on: db)
                try requireOpen(season)
                let seasonID = try season.requireID()
                guard transfer.seasonID == seasonID else {
                    throw Abort(.conflict, reason: "Diese Anfrage gehört nicht zur aktuellen Saison.")
                }
                let accepted = try await Transfer.query(on: db)
                    .filter(\.$seasonID == seasonID)
                    .filter(\.$player == transfer.player)
                    .filter(\.$status == .angenommen)
                    .first()
                guard accepted == nil else {
                    throw Abort(.conflict, reason: "Der Spieler wurde in dieser Saison bereits transferiert.")
                }
                let key = SeasonTransferReservation.key(seasonID: seasonID, playerID: transfer.player)
                if let reservation = try await SeasonTransferReservation.find(key, on: db) {
                    guard reservation.transferID == id else { throw Abort(.conflict) }
                } else {
                    try await SeasonTransferReservation(seasonID: seasonID, playerID: transfer.player, transferID: id)
                        .create(on: db)
                }
                player.$team.id = transfer.team
                try await player.update(on: db)
                transfer.status = .angenommen
            } else {
                if let seasonID = transfer.seasonID,
                   let reservation = try await SeasonTransferReservation.find(
                    SeasonTransferReservation.key(seasonID: seasonID, playerID: transfer.player), on: db
                   ), reservation.transferID == id {
                    try await reservation.delete(on: db)
                }
                if authorizeDestination { transfer.withdrawn = true }
                transfer.status = .abgelehnt
            }
            try await transfer.update(on: db)
            return transfer
        }
    }
}
