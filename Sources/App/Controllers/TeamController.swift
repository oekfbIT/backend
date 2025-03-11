import Vapor
import Fluent

final class TeamController: RouteCollection {
    let repository: StandardControllerRepository<Team>

    init(path: String) {
        self.repository = StandardControllerRepository<Team>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)

        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.get(":id",  "matches" , use: getWithMatches)
        route.delete(":id", use: getWithMatches)

        route.patch(":id", use: updateID)
        route.patch("batch", use: repository.updateBatch)
        
        route.get(":id", "players", use: getTeamWithPlayers)
        route.get(":id", "rechungen", use: getTeamWithRechnungen)
        
        route.get("withPlayers", use: getAllTeamsWithPlayers)

        route.get("search", ":value", use: searchByTeamName)
        
        route.get(":id", "topup", ":amount", use: topUpBalance)
        route.post(":id", "league", ":leagueID", use: assignNewLeague) 
        
        route.get("updateUser", ":teamID", ":newEmailAdress", use: updateUserEmail)
        route.get("overdraft",":id", use: setOverdraftLimit)


    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    func updateID(req: Request) throws -> EventLoopFuture<Team> {
        guard let id = req.parameters.get("id", as: Team.IDValue.self) else {
            throw Abort(.badRequest)
        }

        let updatedItem = try req.content.decode(Team.self)
        return Team.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { item in
                let merged = item.merge(from: updatedItem)
                return item.update(on: req.db).flatMap {
                    // After successfully updating the team, update the related matches
                    return Match.query(on: req.db)
                        .group(.or) { group in
                            group.filter(\.$homeTeam.$id == id)
                            group.filter(\.$awayTeam.$id == id)
                        }
                        .all()
                        .flatMapEach(on: req.eventLoop) { match in
                            if match.$homeTeam.id == id {
                                // Update homeBlanket for home team
                                var updatedBlanket = match.homeBlanket ?? Blankett(name: merged.teamName, dress: merged.trikot.home, logo: merged.logo, players: [], coach: merged.coach)
                                updatedBlanket.name = merged.teamName
                                updatedBlanket.dress = merged.trikot.home
                                updatedBlanket.logo = merged.logo
                                updatedBlanket.coach = merged.coach
                                match.homeBlanket = updatedBlanket
                            } else if match.$awayTeam.id == id {
                                // Update awayBlanket for away team
                                var updatedBlanket = match.awayBlanket ?? Blankett(name: merged.teamName, dress: merged.trikot.away, logo: merged.logo, players: [], coach: merged.coach)
                                updatedBlanket.name = merged.teamName
                                updatedBlanket.dress = merged.trikot.away
                                updatedBlanket.logo = merged.logo
                                updatedBlanket.coach = merged.coach
                                match.awayBlanket = updatedBlanket
                            }
                            return match.update(on: req.db)
                        }
                        .transform(to: merged)
                }
            }
    }

    
    // Function to get a team with all its players
    func getTeamWithPlayers(req: Request) throws -> EventLoopFuture<Team.Public> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Team.query(on: req.db)
            .filter(\.$id == teamID)
            .with(\.$players)
            .first()
            .unwrap(or: Abort(.notFound))
            .map { team in
                var publicTeam = team.asPublic()
                publicTeam.players = team.players.map { $0.asPublic() }
                return publicTeam
            }
    }

    
    func getWithMatches(req: Request) throws -> EventLoopFuture<[Match]> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Match.query(on: req.db)
            .group(.or) { group in
                group.filter(\Match.$homeTeam.$id == teamID)
                group.filter(\Match.$awayTeam.$id == teamID)
            }
            .all()
    }

    // Function to get a team with all its players
    func getTeamWithRechnungen(req: Request) throws -> EventLoopFuture<Team> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Team.query(on: req.db)
            .filter(\.$id == teamID)
            .with(\.$rechnungen)
            .first()
            .unwrap(or: Abort(.notFound))
    }

    
    // Function to get all teams with their players
    func getAllTeamsWithPlayers(req: Request) throws -> EventLoopFuture<[Team.Public]> {
        return Team.query(on: req.db)
            .with(\.$players)
            .all()
            .map { teams in
                teams.map { team in
                    var publicTeam = team.asPublic()
                    publicTeam.players = team.players.map { $0.asPublic() }
                    return publicTeam
                }
            }
    }

    // Function to search for a team by name
    func searchByTeamName(req: Request) throws -> EventLoopFuture<[Team]> {
        guard let teamName = req.parameters.get("value") else {
            throw Abort(.badRequest)
        }
        
        return Team.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$teamName ~~ teamName)
                group.filter(\.$sid ~~ teamName)
            }
            .all()
    }
    
    // Function to top up the balance
    func topUpBalance(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let teamID = req.parameters.get("id", as: UUID.self),
              let amount = req.parameters.get("amount", as: Double.self) else {
            throw Abort(.badRequest)
        }
        
        return Team.find(teamID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { team in
                // Get the current year and generate a random 5-digit number
                let currentYear = Calendar.current.component(.year, from: Date())
                let randomNumber = String.randomNum(length: 5)
                let number = "\(currentYear)-\(randomNumber)"
                
                // Format the current date to "dd.MM.yyyy"
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "dd.MM.yyyy"
                let currentDate = dateFormatter.string(from: Date())
                
                // Set the kennzeichen
                let kennzeichen = "\(currentDate) Guthaben Einzahlung"
                
                let rechnung = Rechnung(team: teamID,
                                        teamName: team.teamName,
                                        number: number,
                                        summ: amount,
                                        topay: nil,
                                        kennzeichen: kennzeichen)
                                        
                team.balance = (team.balance ?? 0) + rechnung.summ
                
                return team.save(on: req.db).flatMap {
                    // Save the new Rechnung to the database
                    return rechnung.create(on: req.db).transform(to: HTTPStatus.ok)
                }
            }
    }

    // Function to assign a new league
    func assignNewLeague(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let teamID = req.parameters.get("id", as: UUID.self),
              let leagueID = req.parameters.get("leagueID", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return League.find(leagueID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { league in
                return Team.find(teamID, on: req.db)
                    .unwrap(or: Abort(.notFound))
                    .flatMap { team in
                        team.$league.id = leagueID
                        return team.save(on: req.db).transform(to: .ok)
                    }
            }
    }
    
    func updateUserEmail(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let teamID = req.parameters.get("teamID", as: UUID.self),
              let newEmail = req.parameters.get("newEmailAdress") else {
            throw Abort(.badRequest)
        }

        return Team.find(teamID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMapThrowing { team in
                guard let userId = team.$user.id else {
                    throw Abort(.badRequest, reason: "No associated user found for this team.")
                }
                
                team.usremail = newEmail
                
                
                return (team, userId)
            }
            .flatMap { (team, userId) in
                
                return User.find(userId, on: req.db)
                    .unwrap(or: Abort(.notFound))
                    .flatMap { user in
                        user.email = newEmail
                        return user.save(on: req.db)
                            .and(team.save(on: req.db))
                            .transform(to: .ok)
                    }
            }
    }
    
    func setOverdraftLimit(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let teamID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Team.find(teamID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { team in
                // First, ensure the balance exists.
                guard let balance = team.balance else {
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Team balance not available"))
                }
                
                // Check if the overdraft flag is already set.
                guard team.overdraft == false else {
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Overdraft already set"))
                }
                
                // Ensure the balance is below 0.
                guard balance < 0 else {
                    return req.eventLoop.future(error: Abort(.badRequest, reason: "Balance is non-negative; overdraft cannot be applied"))
                }
                
                // Conditions met: set overdraft, generate invoice, and update balance.
                team.overdraft = true
                let year = Calendar.current.component(.year, from: Date())
                let randomFiveDigitNumber = String(format: "%05d", Int.random(in: 0..<100000))
                let invoiceNumber = "\(year)\(randomFiveDigitNumber)"
                let rechnungAmount: Double = 50.0
                
                let rechnung = Rechnung(
                    team: team.id,
                    teamName: team.teamName,
                    number: invoiceNumber,
                    summ: rechnungAmount,
                    topay: nil,
                    kennzeichen: "Overdraft"
                )
                
                return rechnung.save(on: req.db).flatMap {
                    team.balance = balance - rechnungAmount
                    return team.save(on: req.db).map {
                        HTTPStatus.ok
                    }
                }
            }
    }
}
