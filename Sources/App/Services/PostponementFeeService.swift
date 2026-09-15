import Fluent
import FluentMongoDriver
import MongoKitten
import Vapor

/// The balance debit and durable receipt share one atomic MongoDB write.
/// A retry repairs a missing invoice from that receipt without debiting again.
struct PostponementFeeReceipt: Codable {
    let fee: AppliedFee
    let before: Double
    let createdAt: Date
}

struct PostponementFeeService {
    let database: Database

    func charge(requestID: UUID, team: Team, fee: AppliedFee) async throws {
        guard let mongo = database as? MongoDatabaseRepresentable else { throw Abort(.serviceUnavailable) }
        let teams = mongo.raw[Team.schema]
        let teamID = try team.requireID()
        let teamKey = try BSONEncoder().encodePrimitive(teamID)!
        let receiptKey = requestID.uuidString.lowercased()
        let path = "postponementFeeReceipts.\(receiptKey)"
        for _ in 0..<20 {
            guard let stored = try await teams.findOne(["_id": teamKey]).get() else { throw Abort(.notFound) }
            if let receipts = stored["postponementFeeReceipts"] as? Document,
               let existing = receipts[receiptKey] as? Document {
                try await ensureInvoice(requestID: requestID, team: team,
                    receipt: BSONDecoder().decode(PostponementFeeReceipt.self, from: existing))
                return
            }
            struct Balance: Decodable { let balance: Double? }
            let before = try BSONDecoder().decode(Balance.self, from: stored).balance ?? 0
            guard before.isFinite else { throw Abort(.conflict, reason: "Team balance is invalid.") }
            let receipt = PostponementFeeReceipt(fee: fee, before: before, createdAt: Date())
            let filter: Document = ["_id": teamKey, "balance": stored["balance"] ?? Null(), path: Null()]
            let changes: Document = ["$set": ["balance": before - fee.euros,
                path: try BSONEncoder().encode(receipt)] as Document]
            let reply = try await teams.findOneAndUpdate(where: filter, to: changes).execute().get()
            guard reply.ok == 1 else { throw reply }
            if reply.value != nil {
                try await ensureInvoice(requestID: requestID, team: team, receipt: receipt)
                return
            }
        }
        throw Abort(.conflict, reason: "Teamkonto wurde gleichzeitig geändert. Bitte erneut versuchen.")
    }

    private func ensureInvoice(requestID: UUID, team: Team, receipt: PostponementFeeReceipt) async throws {
        // Request UUID is a stable invoice id for exactly this postponement.
        if let existing = try await Rechnung.find(requestID, on: database) {
            guard existing.appliedFee == receipt.fee, existing.$team.id == team.id else {
                throw Abort(.conflict, reason: "Spielverlegungsrechnung stimmt nicht mit der Buchung überein.")
            }
            return
        }
        let invoice = Rechnung(id: requestID, team: team.id, teamName: team.teamName,
            number: "VER-\(requestID.uuidString)", summ: receipt.fee.euros, topay: nil,
            previousBalance: receipt.before, kennzeichen: "Spielverlegung", created: receipt.createdAt)
        invoice.appliedFee = receipt.fee
        do { try await invoice.create(on: database) }
        catch {
            guard let existing = try await Rechnung.find(requestID, on: database),
                  existing.appliedFee == receipt.fee, existing.$team.id == team.id else { throw error }
        }
    }
}
