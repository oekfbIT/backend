import Vapor
import Fluent

// MARK: - Stats & Matches Utilities
extension ClientController {
    func getPlayerStats(playerID: UUID, db: Database) -> EventLoopFuture<PlayerStats> {
        
        // 1) All match events for this player (to count goal/card types)
                let eventsFuture = MatchEvent.query(on: db)
                    .filter(\.$player.$id == playerID)
                    .all()
                
                // 2) All matches where the player appears in either homeBlanket or awayBlanket
                let matchesFuture = Match.query(on: db)
                    .all()
                    .map { matches in
                        matches.filter { match in
                            let homeContains = match.homeBlanket?.players.contains { $0.id == playerID } ?? false
                            let awayContains = match.awayBlanket?.players.contains { $0.id == playerID } ?? false
                            return homeContains || awayContains
                        }
                    }
                
                // Combine the two and calculate the summary
                return eventsFuture.and(matchesFuture).map { (events, relevantMatches) in
                    let goalCount = events.filter { $0.type == .goal }.count
                    let redCardCount = events.filter { $0.type == .redCard }.count
                    let yellowCardCount = events.filter { $0.type == .yellowCard }.count
                    let yellowRedCardCount = events.filter { $0.type == .yellowRedCard }.count
                    
                    // Both totalAppearances and totalMatches come from the
                    // blanket-based match count as requested:
                    let totalMatches = relevantMatches.count
                    let totalAppearances = relevantMatches.count
                    
                    return PlayerStats(matchesPlayed: totalMatches,
                                           goalsScored: goalCount,
                                           redCards: redCardCount,
                                           yellowCards: yellowCardCount,
                                           yellowRedCrd: yellowRedCardCount)
                    }
            }

    func getTeamStats(teamID: UUID, db: Database) -> EventLoopFuture<TeamStats> {
        let validStatuses: [GameStatus] = [.completed, .abbgebrochen, .submitted, .cancelled, .done]

        return Match.query(on: db)
            .group(.or) { group in
                group.filter(\.$homeTeam.$id == teamID)
                group.filter(\.$awayTeam.$id == teamID)
            }
            .filter(\.$status ~~ validStatuses)
            .with(\.$events)
            .all()
            .map { matches in
                var stats = TeamStats(
                    wins: 0,
                    draws: 0,
                    losses: 0,
                    totalScored: 0,
                    totalAgainst: 0,
                    goalDifference: 0,
                    totalPoints: 0,
                    totalYellowCards: 0,
                    totalRedCards: 0
                )

                for match in matches {
                    let isHome = match.$homeTeam.id == teamID
                    let scored = isHome ? match.score.home : match.score.away
                    let against = isHome ? match.score.away : match.score.home
                    stats.totalScored += scored
                    stats.totalAgainst += against

                    if scored > against {
                        stats.wins += 1
                        stats.totalPoints += 3
                    } else if scored == against {
                        stats.draws += 1
                        stats.totalPoints += 1
                    } else {
                        stats.losses += 1
                    }

                    for event in match.events {
                        // Infer assign if it is nil
                        let inferredAssign: MatchAssignment = (event.$player.id == match.$homeTeam.id) ? .home : .away

                        // Use the inferred assign if `event.assign` is nil
                        let assign = event.assign ?? inferredAssign

                        // Update yellow/red card stats based on assign
                        if (isHome && assign == .home) || (!isHome && assign == .away) {
                            switch event.type {
                            case .yellowCard:
                                stats.totalYellowCards += 1
                            case .redCard:
                                stats.totalRedCards += 1
                            default:
                                break
                            }
                        }
                    }
                }
                stats.goalDifference = stats.totalScored - stats.totalAgainst
                return stats
            }
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
                                                                                       
