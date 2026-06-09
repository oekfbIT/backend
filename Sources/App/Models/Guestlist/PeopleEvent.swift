//
//  PeopleEvent.swift
//
//
//  Created by Alon Yakoby
//

import Foundation
import Fluent
import Vapor

// MARK: - PeopleEvent Model

final class PeopleEvent: Model, Content, Codable {
    static let schema = "people_events"

    @ID(custom: FieldKeys.id) var id: UUID?

    @OptionalField(key: FieldKeys.title) var title: String?
    @OptionalField(key: FieldKeys.subtitle) var subtitle: String?
    @OptionalField(key: FieldKeys.text) var text: String?
    @OptionalField(key: FieldKeys.image) var image: String?
    @OptionalField(key: FieldKeys.location) var location: String?

    @OptionalField(key: FieldKeys.startDate) var startDate: Date?
    @OptionalField(key: FieldKeys.endDate) var endDate: Date?

    @OptionalField(key: FieldKeys.maxCapacity) var maxCapacity: Int?
    @OptionalField(key: FieldKeys.isRegistrationOpen) var isRegistrationOpen: Bool?
    @OptionalField(key: FieldKeys.registrationDeadline) var registrationDeadline: Date?

    @OptionalField(key: FieldKeys.tag) var tag: String?

    @Timestamp(key: FieldKeys.created, on: .create) var created: Date?

    @Children(for: \.$event) var guests: [PeopleEventGuest]

    struct FieldKeys {
        static var id: FieldKey { "id" }
        static var title: FieldKey { "title" }
        static var subtitle: FieldKey { "subtitle" }
        static var text: FieldKey { "text" }
        static var image: FieldKey { "image" }
        static var location: FieldKey { "location" }
        static var startDate: FieldKey { "start_date" }
        static var endDate: FieldKey { "end_date" }
        static var maxCapacity: FieldKey { "max_capacity" }
        static var isRegistrationOpen: FieldKey { "is_registration_open" }
        static var registrationDeadline: FieldKey { "registration_deadline" }
        static var tag: FieldKey { "tag" }
        static var created: FieldKey { "created" }
    }

    init() {}

    init(
        id: UUID? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        text: String? = nil,
        image: String? = nil,
        location: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        maxCapacity: Int? = nil,
        isRegistrationOpen: Bool? = true,
        registrationDeadline: Date? = nil,
        tag: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.image = image
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.maxCapacity = maxCapacity
        self.isRegistrationOpen = isRegistrationOpen
        self.registrationDeadline = registrationDeadline
        self.tag = tag
        self.created = Date.viennaNow
    }
}

// MARK: - PeopleEvent Mergeable

extension PeopleEvent: Mergeable {
    func merge(from other: PeopleEvent) -> PeopleEvent {
        var merged = self
        merged.title = other.title ?? self.title
        merged.subtitle = other.subtitle ?? self.subtitle
        merged.text = other.text ?? self.text
        merged.image = other.image ?? self.image
        merged.location = other.location ?? self.location
        merged.startDate = other.startDate ?? self.startDate
        merged.endDate = other.endDate ?? self.endDate
        merged.maxCapacity = other.maxCapacity ?? self.maxCapacity
        merged.isRegistrationOpen = other.isRegistrationOpen ?? self.isRegistrationOpen
        merged.registrationDeadline = other.registrationDeadline ?? self.registrationDeadline
        merged.tag = other.tag ?? self.tag
        merged.created = other.created ?? self.created
        return merged
    }
}

