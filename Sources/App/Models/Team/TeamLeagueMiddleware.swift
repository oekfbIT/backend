import Fluent
import Vapor

/// The relationship is authoritative; leagueCode is a compatibility snapshot.
struct TeamLeagueMiddleware: ModelMiddleware {
    func create(model: Team, on db: Database, next: AnyModelResponder) -> EventLoopFuture<Void> {
        synchronize(model, on: db).flatMap { next.create(model, on: db) }
    }

    func update(model: Team, on db: Database, next: AnyModelResponder) -> EventLoopFuture<Void> {
        synchronize(model, on: db).flatMap { next.update(model, on: db) }
    }

    private func synchronize(_ team: Team, on db: Database) -> EventLoopFuture<Void> {
        guard let id = team.$league.id else {
            team.leagueCode = nil
            return db.eventLoop.makeSucceededFuture(())
        }
        return League.find(id, on: db)
            .unwrap(or: Abort(.badRequest, reason: "Assigned league does not exist."))
            .map { team.leagueCode = $0.name }
    }
}
