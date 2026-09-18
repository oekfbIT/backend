import Foundation
import Fluent
import Vapor

enum RechnungStatus: String, Codable {
    case offen, bezahlt
}

final class Rechnung: Model, Content, Codable {
    static let schema = "rechnungen"

    @ID(custom: .id) var id: UUID?
    @OptionalParent(key: FieldKeys.teamID) var team: Team?
    @Field(key: FieldKeys.status) var status: RechnungStatus
    @Field(key: FieldKeys.teamName) var teamName: String
    @Field(key: FieldKeys.number) var number: String
    @Field(key: FieldKeys.summ) var summ: Double
    @Field(key: FieldKeys.topay) var topay: Double?
    @OptionalField(key: FieldKeys.previousBalance) var previousBalance: Double?
    @Field(key: FieldKeys.kennzeichen) var kennzeichen: String
    @Field(key: FieldKeys.dueDate) var dueDate: String?
    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?
    @OptionalField(key: "paymentSource") var paymentSource: String?
    @OptionalField(key: "stripeDeposit") var stripeDeposit: StripeDepositDetails?
    @OptionalField(key: "appliedFee") var appliedFee: AppliedFee?
    // Internal capability; Fluent does not encode ordinary stored properties.
    var allowsStripeCreation = false

    func requireManualEntry() throws {
        guard paymentSource != "stripe", stripeDeposit == nil else {
            throw Abort(.conflict, reason: "Stripe deposits are immutable and already credited.")
        }
    }

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var teamID: FieldKey { "teamID" }
        static var status: FieldKey { "status" }
        static var teamName: FieldKey { "teamName" }
        static var number: FieldKey { "number" }
        static var summ: FieldKey { "summ" }
        static var topay: FieldKey { "topay" }
        static var kennzeichen: FieldKey { "kennzeichen" }
        static var dueDate: FieldKey { "due_date" }
        static var created: FieldKey { "created" }
        static var previousBalance: FieldKey { "previousBalance" }
    }

    init() {}

    init(
        id: UUID? = nil,
        team: UUID?,
        teamName: String,
        status: RechnungStatus = .offen,
        number: String,
        summ: Double,
        topay: Double?,
        previousBalance: Double? = nil ,
        kennzeichen: String,
        created: Date? = nil
    ) {
        self.id = id
        self.$team.id = team
        self.teamName = teamName
        self.status = status
        self.number = number
        self.summ = summ
        self.topay = topay ?? summ
        self.previousBalance = previousBalance
        self.kennzeichen = kennzeichen
        self.created = created ?? Date.viennaNow
        self.paymentSource = "manual"
        
        // Generate due date based on the created date
        let calendar = Calendar.current
        if let dueDate = calendar.date(byAdding: .weekOfYear, value: 2, to: self.created!) {
            self.dueDate = DateFormatter.localizedString(from: dueDate, dateStyle: .short, timeStyle: .none)
        }
    }

    func generateDueDate() {
        if let createdDate = created {
            let calendar = Calendar.current
            if let dueDate = calendar.date(byAdding: .weekOfYear, value: 2, to: createdDate) {
                self.dueDate = DateFormatter.localizedString(from: dueDate, dateStyle: .short, timeStyle: .none)
            }
        }
    }

    func didCreate(on database: Database) -> EventLoopFuture<Void> {
        generateDueDate()
        return self.update(on: database)
    }
}

extension Rechnung {
    /// Team-facing invoice representation. Stripe intent, charge and top-up
    /// identifiers are deliberately omitted; administrators retain the full
    /// model through the protected admin endpoints.
    struct Public: Content {
        let id: UUID?
        let teamID: UUID?
        let status: RechnungStatus
        let teamName: String
        let number: String
        let summ: Double
        let topay: Double?
        let previousBalance: Double?
        let kennzeichen: String
        let dueDate: String?
        let created: Date?
        let paymentSource: String?
        let appliedFee: AppliedFee?
    }

    func asPublic() -> Public {
        Public(
            id: id,
            teamID: $team.id,
            status: status,
            teamName: teamName,
            number: number,
            summ: summ,
            topay: topay,
            previousBalance: previousBalance,
            kennzeichen: kennzeichen,
            dueDate: dueDate,
            created: created,
            paymentSource: paymentSource,
            appliedFee: appliedFee
        )
    }
}

extension Rechnung: Mergeable {
    func merge(from other: Rechnung) -> Rechnung {
        var merged = self
        merged.id = other.id
        merged.$team.id = other.$team.id
        merged.status = other.status
        merged.teamName = other.teamName
        merged.number = other.number
        merged.summ = other.summ
        merged.topay = other.topay
        merged.previousBalance = other.previousBalance
        merged.kennzeichen = other.kennzeichen
        merged.dueDate = other.dueDate
        merged.created = other.created
        return merged
    }
}

// Migration
extension RechnungMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Rechnung.schema)
            .id()
            .field(Rechnung.FieldKeys.teamID, .uuid, .required, .references(Team.schema, .id))
            .field(Rechnung.FieldKeys.status, .string, .required)
            .field(Rechnung.FieldKeys.teamName, .string, .required)
            .field(Rechnung.FieldKeys.number, .string, .required)
            .field(Rechnung.FieldKeys.summ, .double, .required)
            .field(Rechnung.FieldKeys.previousBalance, .double)
            .field(Rechnung.FieldKeys.topay, .double)
            .field(Rechnung.FieldKeys.kennzeichen, .string, .required)
            .field(Rechnung.FieldKeys.dueDate, .string)
            .field(Rechnung.FieldKeys.created, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Rechnung.schema).delete()
    }
}
