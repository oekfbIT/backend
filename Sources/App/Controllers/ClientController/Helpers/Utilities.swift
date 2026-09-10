import Vapor
import Fluent

// MARK: - Stats & Matches Utilities
extension ClientController {
    func getPlayerStats(playerID: UUID, db: Database) -> EventLoopFuture<PlayerStats> {
        PlayerStatisticsService.calculate(playerID: playerID, on: db).map(\.all)
    }

    func getTeamStats(teamID: UUID, db: Database) -> EventLoopFuture<TeamStats> {
        StatsCacheManager.getTeamStats(for: teamID, on: db)
    }

    /// Returns all matches for a given team (home or away) as PublicMatchShort
    func getAllMatchesForTeam(teamID: UUID, db: Database) -> EventLoopFuture<[PublicMatchShort]> {
        return Match.query(on: db)
            .group(.or) { group in
                group.filter(\.$homeTeam.$id == teamID)
                group.filter(\.$awayTeam.$id == teamID)
            }
            .with(\.$homeTeam)
            .with(\.$awayTeam)
            .with(\.$events)
            .all()
            .map { matches in
                matches.map { match in
                    PublicMatchShort(
                        id: match.id,
                        details: match.details,
                        homeBlanket: MiniBlankett(
                            id: match.$homeTeam.id,
                            logo: match.homeBlanket?.logo,
                            name: match.homeBlanket?.name
                        ),
                        awayBlanket: MiniBlankett(
                            id: match.$awayTeam.id,
                            logo: match.awayBlanket?.logo,
                            name: match.awayBlanket?.name
                        ),
                        score: match.score,
                        status: match.status,
                        firstHalfDate: match.firstHalfStartDate,
                        secondHalfDate: match.secondHalfStartDate
                    )
                }
            }
    }

    // MARK: Upcoming Matches Helper
    func getUpcomingMatchesWithinNext7Days(from seasons: [Season]) -> [Match] {
        let allMatches = seasons.flatMap { $0.matches }
        let calendar = Calendar.current

        // Start of today (00:00)
        let now = Date.viennaNow
        guard let startOfToday = calendar.startOfDay(for: now) as Date?,
              let endDate = calendar.date(byAdding: .day, value: 7, to: startOfToday) else {
            return []
        }

        return allMatches.filter { match in
            guard let matchDate = match.details.date else { return false }
            return matchDate >= startOfToday && matchDate <= endDate
        }
    }

    // MARK: Helper Mapping
    func mapTeamsToPublic(_ teams: [Team]) -> [PublicTeamShort] {
        return teams.map { team in
            PublicTeamShort(
                id: team.id,
                sid: team.sid,
                logo: team.logo,
                points: team.points,
                teamName: team.teamName
            )
        }
    }

    func mapMatchesToShort(_ matches: [Match]) -> [PublicMatchShort] {
        return matches.map { match in
            PublicMatchShort(
                id: match.id,
                details: match.details,
                homeBlanket: MiniBlankett(
                    id: match.$homeTeam.id,
                    logo: match.homeBlanket?.logo,
                    name: match.homeBlanket?.name
                ),
                awayBlanket: MiniBlankett(
                    id: match.$awayTeam.id,
                    logo: match.awayBlanket?.logo,
                    name: match.awayBlanket?.name
                ),
                score: match.score,
                status: match.status,
                firstHalfDate: match.firstHalfStartDate,
                secondHalfDate: match.secondHalfStartDate
            )
        }
    }
}

extension ClientController {
    func getTeamStatsPair(teamID: UUID, db: Database) -> EventLoopFuture<TeamStatsPair> {
        TeamStatisticsService.calculate(teamIDs: [teamID], on: db).map {
            $0[teamID] ?? TeamStatsPair(all: TeamStatisticsService.emptyStats(), season: TeamStatisticsService.emptyStats())
        }
    }
}

extension HomepageController {
    func getTeamStatsPair(teamID: UUID, db: Database) -> EventLoopFuture<TeamStatsPair> {
        TeamStatisticsService.calculate(teamIDs: [teamID], on: db).map {
            $0[teamID] ?? TeamStatsPair(all: TeamStatisticsService.emptyStats(), season: TeamStatisticsService.emptyStats())
        }
    }
}

                                                                                       
