import Foundation
import Fluent
import Vapor

struct PublicSearchTeam: Content {
    let id: UUID
    let sid: String
    let logo: String
    let team_name: String
    let league_id: UUID?
    let league_code: String?
    let league_name: String?
}

struct PublicSearchPlayer: Content {
    let id: UUID
    let sid: String
    let image: String
    let name: String
    let number: String
    let birthday: String
    let nationality: String
    let eligibility: PlayerEligibility
    let team_id: UUID?
    let team_name: String?
    let team_logo: String?
    let league_id: UUID?
    let league_code: String?
    let league_name: String?
}

struct PublicSearchResults: Content {
    let teams: [PublicSearchTeam]
    let teams_count: Int
    let players: [PublicSearchPlayer]
    let players_count: Int
}

extension ClientController {
    /// Public, read-only search used by the website.
    /// GET /webClient/search?query=...
    func search(req: Request) async throws -> PublicSearchResults {
        guard let suppliedQuery = try? req.query.get(String.self, at: "query") else {
            throw Abort(.badRequest, reason: "Query cannot be empty.")
        }

        let query = suppliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            throw Abort(.badRequest, reason: "Query cannot be empty.")
        }

        let pattern = NSRegularExpression.escapedPattern(for: query)

        async let teamsCount = Team.query(on: req.db)
            .mongoRegex("teamName", pattern)
            .count()
        async let teams = Team.query(on: req.db)
            .with(\.$league)
            .with(\.$players)
            .mongoRegex("teamName", pattern)
            .sort(\.$teamName, .ascending)
            .limit(50)
            .all()
        async let directlyMatchingPlayers = Player.query(on: req.db)
            .with(\.$team) { team in
                team.with(\.$league)
            }
            .mongoRegex("name", pattern)
            .sort(\.$name, .ascending)
            .limit(50)
            .all()

        let (teamTotal, teamModels, directPlayerModels) = try await (
            teamsCount,
            teams,
            directlyMatchingPlayers
        )

        // A team-name hit also contributes every player on that team. Merge
        // those with direct player-name hits and de-duplicate by player ID.
        var playerMatches: [UUID: (player: Player, team: Team?)] = [:]

        for team in teamModels {
            for player in team.players {
                playerMatches[try player.requireID()] = (player, team)
            }
        }

        for player in directPlayerModels {
            let playerID = try player.requireID()
            if playerMatches[playerID] == nil {
                playerMatches[playerID] = (player, player.team)
            }
        }

        let sortedPlayerMatches = playerMatches.values.sorted {
            $0.player.name.localizedCaseInsensitiveCompare($1.player.name) == .orderedAscending
        }

        return PublicSearchResults(
            teams: try teamModels.map { team in
                PublicSearchTeam(
                    id: try team.requireID(),
                    sid: team.sid ?? "",
                    logo: team.logo,
                    team_name: team.teamName,
                    league_id: team.league?.id ?? team.$league.id,
                    league_code: team.league?.code ?? team.leagueCode,
                    league_name: team.league?.name
                )
            },
            teams_count: teamTotal,
            players: try sortedPlayerMatches.map { match in
                let player = match.player
                let team = match.team
                return PublicSearchPlayer(
                    id: try player.requireID(),
                    sid: player.sid,
                    image: player.image ?? "",
                    name: player.name,
                    number: player.number,
                    birthday: player.birthday,
                    nationality: player.nationality,
                    eligibility: player.eligibility,
                    team_id: team?.id,
                    team_name: team?.teamName,
                    team_logo: team?.logo,
                    league_id: team?.league?.id ?? team?.$league.id,
                    league_code: team?.league?.code ?? team?.leagueCode,
                    league_name: team?.league?.name
                )
            },
            players_count: sortedPlayerMatches.count
        )
    }
}
