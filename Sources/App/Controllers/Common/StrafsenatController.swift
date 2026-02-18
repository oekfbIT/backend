//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//
  

import Vapor
import Fluent

final class StrafsenatController: RouteCollection {
    let repository: StandardControllerRepository<Strafsenat>

    init(path: String) {
        self.repository = StandardControllerRepository<Strafsenat>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: repository.create)
        route.post("batch", use: repository.createBatch)

        route.get(use: index)
        route.get(":id", use: repository.getbyID)
        route.delete(":id", use: repository.deleteID)

        route.patch(":id", use: repository.updateID)
        route.patch("batch", use: repository.updateBatch)
        
        // Add the close and open routes???
        route.patch(":id","close", use: close)
        route.patch(":id","open", use: open)
    }
   
    struct TeamInfo: Content {
        let id: UUID
        let teamName: String
        let image: String
    }

    struct StrafsenatResponse: Content {
        let id: UUID?
        let text: String?
        let matchID: UUID
        let refID: UUID
        let offen: Bool
        let created: Date?
        let hometeam: TeamInfo
        let awayteam: TeamInfo
    }

    func index(req: Request) throws -> EventLoopFuture<[StrafsenatResponse]> {
        let strafsenatsFuture = Strafsenat.query(on: req.db).all()
        let matchesFuture = Match.query(on: req.db).all()
        let teamsFuture = Team.query(on: req.db).all()

        return strafsenatsFuture.and(matchesFuture).and(teamsFuture).map { result in
            let ((strafsenats, matches), teams) = result

            let matchMap = Dictionary(uniqueKeysWithValues: matches.compactMap { match in
                match.id.map { ($0, match) }
            })

            let teamMap = Dictionary(uniqueKeysWithValues: teams.compactMap { team in
                team.id.map { ($0, team) }
            })

            return strafsenats.compactMap { straf in
                guard
//                    let matchID = straf.$match.id,
                    let match = matchMap[straf.$match.id],
                    let homeTeam = teamMap[match.$homeTeam.id],
                    let awayTeam = teamMap[match.$awayTeam.id]
                else {
                    return nil
                }

                return StrafsenatResponse(
                    id: straf.id,
                    text: straf.text,
                    matchID: straf.$match.id,
                    refID: straf.refID,
                    offen: straf.offen,
                    created: straf.created,
                    hometeam: TeamInfo(id: homeTeam.id!, teamName: homeTeam.teamName, image: homeTeam.logo),
                    awayteam: TeamInfo(id: awayTeam.id!, teamName: awayTeam.teamName, image: awayTeam.logo)
                )
            }
        }
    }

    // Function to close the status (set offen to false)
    func close(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        return Strafsenat.find(req.parameters.get("id"), on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { strafsenat in
                strafsenat.offen = false
                return strafsenat.save(on: req.db).transform(to: .ok)
            }
    }

    // Function to open the status (set offen to true)
    func open(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        return Strafsenat.find(req.parameters.get("id"), on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { strafsenat in
                strafsenat.offen = true
                return strafsenat.save(on: req.db).transform(to: .ok)
            }
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
}
