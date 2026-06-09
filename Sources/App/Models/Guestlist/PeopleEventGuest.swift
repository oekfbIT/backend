//
//  PeopleEvent.swift
//
//
//  Created by Alon Yakoby
//

import Foundation
import Fluent
import Vapor

// MARK: - PeopleEventGuest Model

final class PeopleEventGuest: Model, Content, Codable {
    static let schema = "people_event_guests"

    @ID(custom: FieldKeys.id) var id: UUID?

    @Parent(key: FieldKeys.eventID) var event: PeopleEvent

    @OptionalField(key: FieldKeys.name) var name: String?
    @OptionalField(key: FieldKeys.team) var team: String?
    @OptionalField(key: FieldKeys.email) var email: String?
    @OptionalField(key: FieldKeys.phone) var phone: String?

    /// Total number of people for this registration.
    /// Example: 1 means only the main guest.
    @OptionalField(key: FieldKeys.numberOfPeople) var numberOfPeople: Int?

    /// Optional list of guest names.
    /// Example: ["Sarah", "David", "Noa"]
    @OptionalField(key: FieldKeys.additionalGuestNames) var additionalGuestNames: [String]?

    /// Example values:
    /// "open", "confirmed", "cancelled", "waitlist"
    @OptionalField(key: FieldKeys.status) var status: String?

    @OptionalField(key: FieldKeys.notes) var notes: String?

    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?
    @Timestamp(key: FieldKeys.updated, on: .update) var updated: Date?

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var eventID: FieldKey { "event_id" }
        static var name: FieldKey { "name" }
        static var team: FieldKey { "team" }
        static var email: FieldKey { "email" }
        static var phone: FieldKey { "phone" }
        static var numberOfPeople: FieldKey { "number_of_people" }
        static var additionalGuestNames: FieldKey { "additional_guest_names" }
        static var status: FieldKey { "status" }
        static var notes: FieldKey { "notes" }
        static var created: FieldKey { "created" }
        static var updated: FieldKey { "updated" }
    }

    init() {}

    init(
        id: UUID? = nil,
        eventID: PeopleEvent.IDValue,
        name: String? = nil,
        team: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        numberOfPeople: Int? = 1,
        additionalGuestNames: [String]? = nil,
        status: String? = "open",
        notes: String? = nil
    ) {
        self.id = id
        self.$event.id = eventID
        self.name = name
        self.team = team
        self.email = email
        self.phone = phone
        self.numberOfPeople = numberOfPeople
        self.additionalGuestNames = additionalGuestNames
        self.status = status
        self.notes = notes
        self.created = Date.viennaNow
    }
}

// MARK: - PeopleEventGuest Mergeable

extension PeopleEventGuest: Mergeable {
    func merge(from other: PeopleEventGuest) -> PeopleEventGuest {
        var merged = self
        merged.name = other.name ?? self.name
        merged.team = other.team ?? self.team
        merged.email = other.email ?? self.email
        merged.phone = other.phone ?? self.phone
        merged.numberOfPeople = other.numberOfPeople ?? self.numberOfPeople
        merged.additionalGuestNames = other.additionalGuestNames ?? self.additionalGuestNames
        merged.status = other.status ?? self.status
        merged.notes = other.notes ?? self.notes
        merged.created = other.created ?? self.created
        merged.updated = other.updated ?? self.updated
        return merged
    }
}

// MARK: - DTOs

struct PeopleEventCreateDTO: Content {
    var title: String?
    var subtitle: String?
    var text: String?
    var image: String?
    var location: String?
    var startDate: Date?
    var endDate: Date?
    var maxCapacity: Int?
    var isRegistrationOpen: Bool?
    var registrationDeadline: Date?
    var tag: String?

    func toModel() -> PeopleEvent {
        PeopleEvent(
            title: title,
            subtitle: subtitle,
            text: text,
            image: image,
            location: location,
            startDate: startDate,
            endDate: endDate,
            maxCapacity: maxCapacity,
            isRegistrationOpen: isRegistrationOpen ?? true,
            registrationDeadline: registrationDeadline,
            tag: tag
        )
    }
}

struct PeopleEventUpdateDTO: Content {
    var title: String?
    var subtitle: String?
    var text: String?
    var image: String?
    var location: String?
    var startDate: Date?
    var endDate: Date?
    var maxCapacity: Int?
    var isRegistrationOpen: Bool?
    var registrationDeadline: Date?
    var tag: String?
}

struct PeopleEventResponseDTO: Content {
    var id: UUID?
    var title: String?
    var subtitle: String?
    var text: String?
    var image: String?
    var location: String?
    var startDate: Date?
    var endDate: Date?
    var maxCapacity: Int?
    var isRegistrationOpen: Bool?
    var registrationDeadline: Date?
    var tag: String?
    var created: Date?

    var registeredGuests: Int?
    var registeredPeople: Int?

    init(
        from event: PeopleEvent,
        registeredGuests: Int? = nil,
        registeredPeople: Int? = nil
    ) {
        self.id = event.id
        self.title = event.title
        self.subtitle = event.subtitle
        self.text = event.text
        self.image = event.image
        self.location = event.location
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.maxCapacity = event.maxCapacity
        self.isRegistrationOpen = event.isRegistrationOpen
        self.registrationDeadline = event.registrationDeadline
        self.tag = event.tag
        self.created = event.created
        self.registeredGuests = registeredGuests
        self.registeredPeople = registeredPeople
    }
}

struct PeopleEventGuestCreateDTO: Content {
    var name: String
    var team: String?
    var email: String?
    var phone: String?
    var numberOfPeople: Int?
    var additionalGuestNames: [String]?
    var status: String?
    var notes: String?

    func toModel(eventID: PeopleEvent.IDValue) -> PeopleEventGuest {
        PeopleEventGuest(
            eventID: eventID,
            name: name,
            team: team,
            email: email,
            phone: phone,
            numberOfPeople: numberOfPeople ?? 1,
            additionalGuestNames: additionalGuestNames,
            status: status ?? "open",
            notes: notes
        )
    }
}

struct PeopleEventGuestUpdateDTO: Content {
    var name: String?
    var team: String?
    var email: String?
    var phone: String?
    var numberOfPeople: Int?
    var additionalGuestNames: [String]?
    var status: String?
    var notes: String?
}

struct PeopleEventGuestResponseDTO: Content {
    var id: UUID?
    var eventID: UUID?
    var name: String?
    var team: String?
    var email: String?
    var phone: String?
    var numberOfPeople: Int?
    var additionalGuestNames: [String]?
    var status: String?
    var notes: String?
    var created: Date?
    var updated: Date?

    init(from guest: PeopleEventGuest) {
        self.id = guest.id
        self.eventID = guest.$event.id
        self.name = guest.name
        self.team = guest.team
        self.email = guest.email
        self.phone = guest.phone
        self.numberOfPeople = guest.numberOfPeople
        self.additionalGuestNames = guest.additionalGuestNames
        self.status = guest.status
        self.notes = guest.notes
        self.created = guest.created
        self.updated = guest.updated
    }
}

// MARK: - Migrations

struct PeopleEventMigration {}

extension PeopleEventMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(PeopleEvent.schema)
            .field(PeopleEvent.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(PeopleEvent.FieldKeys.title, .string)
            .field(PeopleEvent.FieldKeys.subtitle, .string)
            .field(PeopleEvent.FieldKeys.text, .string)
            .field(PeopleEvent.FieldKeys.image, .string)
            .field(PeopleEvent.FieldKeys.location, .string)
            .field(PeopleEvent.FieldKeys.startDate, .datetime)
            .field(PeopleEvent.FieldKeys.endDate, .datetime)
            .field(PeopleEvent.FieldKeys.maxCapacity, .int)
            .field(PeopleEvent.FieldKeys.isRegistrationOpen, .bool)
            .field(PeopleEvent.FieldKeys.registrationDeadline, .datetime)
            .field(PeopleEvent.FieldKeys.tag, .string)
            .field(PeopleEvent.FieldKeys.created, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(PeopleEvent.schema).delete()
    }
}

struct PeopleEventGuestMigration {}

extension PeopleEventGuestMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(PeopleEventGuest.schema)
            .field(PeopleEventGuest.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(
                PeopleEventGuest.FieldKeys.eventID,
                .uuid,
                .required,
                .references(PeopleEvent.schema, PeopleEvent.FieldKeys.id, onDelete: .cascade)
            )
            .field(PeopleEventGuest.FieldKeys.name, .string)
            .field(PeopleEventGuest.FieldKeys.team, .string)
            .field(PeopleEventGuest.FieldKeys.email, .string)
            .field(PeopleEventGuest.FieldKeys.phone, .string)
            .field(PeopleEventGuest.FieldKeys.numberOfPeople, .int)
            .field(PeopleEventGuest.FieldKeys.additionalGuestNames, .array(of: .string))
            .field(PeopleEventGuest.FieldKeys.status, .string)
            .field(PeopleEventGuest.FieldKeys.notes, .string)
            .field(PeopleEventGuest.FieldKeys.created, .datetime)
            .field(PeopleEventGuest.FieldKeys.updated, .datetime)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(PeopleEventGuest.schema).delete()
    }
}
