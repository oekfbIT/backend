import Fluent
import Crypto
import FluentMongoDriver
import MongoKitten
import Vapor

/// Durable, atomic receipts make retries safe even across server instances.
struct TeamBookingStore {
    let database: Database

    func apply(teamID: UUID, key: String,
               changes: (Document) throws -> Document) async throws -> Document {
        guard let mongo = database as? MongoDatabaseRepresentable else { throw Abort(.serviceUnavailable) }
        let teams = mongo.raw[Team.schema]
        let id = try BSONEncoder().encodePrimitive(teamID)!
        let path = "matchBookingReceipts.\(key)"
        for _ in 0..<30 {
            guard let stored = try await teams.findOne(["_id": id]).get() else { throw Abort(.notFound) }
            if let receipts = stored["matchBookingReceipts"] as? Document,
               let receipt = receipts[key] as? Document { return receipt }
            let receipt = try changes(stored)
            var set: Document = [:]
            for (field, value) in receipt where !field.hasPrefix("_") { set[field] = value }
            set[path] = receipt
            // Match every field being changed to avoid losing concurrent bookings.
            var filter: Document = ["_id": id, path: Null()]
            for (field, _) in receipt where !field.hasPrefix("_") { filter[field] = stored[field] ?? Null() }
            if try await teams.findOneAndUpdate(where: filter, to: ["$set": set]).stripeExecute().get() != nil {
                return receipt
            }
        }
        throw Abort(.conflict, reason: "Teamkonto wurde gleichzeitig geändert. Bitte erneut versuchen.")
    }

    static func identifier(_ id: UUID, namespace: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("\(namespace):\(id.uuidString)".utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func balance(_ document: Document) throws -> Double {
        struct Value: Decodable { let balance: Double? }
        let value = try BSONDecoder().decode(Value.self, from: document).balance ?? 0
        guard value.isFinite else { throw Abort(.conflict, reason: "Ungültiger Kontostand.") }
        return value
    }
}

struct MatchCancellationService {
    static func cancel(req: Request, matchID: UUID, winningSide: String) async throws -> HTTPStatus {
        let side = winningSide.lowercased()
        guard side == "home" || side == "away" else { throw Abort(.badRequest) }
        let fees = try await FeeService.forRequest(req)
        guard let mongo = req.db as? MongoDatabaseRepresentable else { throw Abort(.serviceUnavailable) }
        let matchDB = try await Match.query(on: req.db)
            .with(\.$homeTeam) { $0.with(\.$user) }
            .with(\.$awayTeam) { $0.with(\.$user) }
            .with(\.$referee) { $0.with(\.$user) }
            .filter(\.$id == matchID).first()
        guard let match = matchDB else { throw Abort(.notFound) }
        let matches = mongo.raw[Match.schema]
        let id = try BSONEncoder().encodePrimitive(matchID)!
        // Fix the winner before any side effects. A retry resumes the same operation.
        let claimed = try await matches.findOneAndUpdate(
            where: ["_id": id, "status": "pending", "cancellationWinner": Null()],
            to: ["$set": ["cancellationWinner": side]]).stripeExecute().get()
        if claimed == nil {
            guard let stored = try await matches.findOne(["_id": id]).get() else { throw Abort(.notFound) }
            if let winner = stored["cancellationWinner"] as? String {
                guard winner == side else { throw Abort(.conflict, reason: "Die Spielabsage wurde bereits erfasst.") }
                if stored["status"] as? String == "cancelled" { return .ok }
            } else if match.status == .cancelled { return .ok }
            else { throw Abort(.conflict, reason: "Dieses Spiel kann nicht abgesagt werden.") }
        }
        let winner = side == "home" ? match.homeTeam : match.awayTeam
        let loser = side == "home" ? match.awayTeam : match.homeTeam
        let key = matchID.uuidString.lowercased()
        let store = TeamBookingStore(database: req.db)
        let receipt = try await store.apply(teamID: loser.requireID(), key: "cancel-\(key)") { stored in
            struct Count: Decodable { let cancelled: Int? }
            let count = try BSONDecoder().decode(Count.self, from: stored).cancelled ?? 0
            guard count >= 0, count < 3 else { throw Abort(.badRequest, reason: "Schon 3 Absagen gemacht diese Saison.") }
            let fee = fees.fee(try FeeKey.cancellation(count + 1))
            return ["balance": try TeamBookingStore.balance(stored) - fee.euros, "cancelled": count + 1, "_fee": try BSONEncoder().encode(fee), "_before": try TeamBookingStore.balance(stored)]
        }
        struct Booking: Decodable { let balance: Double; let cancelled: Int; let _fee: AppliedFee; let _before: Double }
        let booking = try BSONDecoder().decode(Booking.self, from: receipt)
        // The receipt fixes the tier. Preserve the charged amount across fee updates.
        let invoiceID = TeamBookingStore.identifier(matchID, namespace: "cancellation")
        if try await Rechnung.find(invoiceID, on: req.db) == nil {
            let fee = booking._fee
            let invoice = Rechnung(id: invoiceID, team: loser.id, teamName: loser.teamName,
                number: "ABS-\(key)", summ: fee.euros, topay: nil,
                previousBalance: booking._before, kennzeichen: "Spiel Absage: \(booking.cancelled)")
            invoice.appliedFee = fee
            do { try await invoice.create(on: req.db) }
            catch { if try await Rechnung.find(invoiceID, on: req.db) == nil { throw error } }
        }
        _ = try await store.apply(teamID: winner.requireID(), key: "win-\(key)") { stored in
            struct Points: Decodable { let points: Int }
            return ["points": try BSONDecoder().decode(Points.self, from: stored).points + 3]
        }
        // Only one caller sends notifications, after all financial writes have succeeded.
        let completed = try await matches.findOneAndUpdate(
            where: ["_id": id, "status": "pending", "cancellationWinner": side],
            to: ["$set": ["status": "cancelled", "score": try BSONEncoder().encode(Score(home: side == "home" ? 6 : 0, away: side == "away" ? 6 : 0))] as Document]).stripeExecute().get()
        guard completed != nil else { return .ok }
        match.status = .cancelled
        match.score = Score(home: side == "home" ? 6 : 0, away: side == "away" ? 6 : 0)
        do { try await StatsCacheManager.invalidateStats(for: match, on: req.db).get() }
        catch { req.logger.warning("Unable to invalidate cancellation stats: \(error)") }
        do {
            let email = EmailController()
            if let recipient = winner.user?.email, !recipient.isEmpty {
                _ = try await email.sendCancellationNotification(req: req, recipient: recipient, match: match).get()
            }
            if let referee = match.referee, let user = referee.user {
                _ = try await email.informRefereeCancellation(req: req, email: user.email, name: referee.name ?? "Referee", match: match).get()
            }
        } catch { req.logger.warning("Unable to send cancellation notification: \(error)") }
        return .ok
    }
}
