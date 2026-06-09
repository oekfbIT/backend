//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//

import Vapor
import Fluent

final class PeopleEventController: RouteCollection {
    let repository: StandardControllerRepository<PeopleEvent>

    init(path: String) {
        self.repository = StandardControllerRepository<PeopleEvent>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))

        // MARK: - Event Routes

        route.post(use: createEvent)
        route.get(use: getAllEvents)
        route.get("with-counts", use: getAllEventsWithCounts)

        route.get(":id", use: getEventByID)
        route.patch(":id", use: updateEventByID)
        route.delete(":id", use: deleteEventByID)

        // MARK: - Guest List Routes

        route.get(":id", "guests", use: getGuestsForEvent)
        route.post(":id", "guests", use: addGuestToEvent)
        route.post(":id", "register", use: addGuestToEvent)

        route.get(":id", "guests", ":guestID", use: getGuestByID)
        route.patch(":id", "guests", ":guestID", use: updateGuestByID)
        route.delete(":id", "guests", ":guestID", use: deleteGuestFromEvent)

        // MARK: - Utility Routes

        route.get(":id", "summary", use: getEventSummary)
        route.patch(":id", "open", use: openRegistration)
        route.patch(":id", "close", use: closeRegistration)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }

    // MARK: - Events

    func createEvent(req: Request) throws -> EventLoopFuture<PeopleEvent> {
        let dto = try req.content.decode(PeopleEventCreateDTO.self)
        let event = dto.toModel()

        return event.save(on: req.db).map { event }
    }

    func getAllEvents(req: Request) throws -> EventLoopFuture<[PeopleEvent]> {
        PeopleEvent.query(on: req.db)
            .sort(\.$created, .descending)
            .all()
    }

    func getEventByID(req: Request) throws -> EventLoopFuture<PeopleEvent> {
        guard let id = req.parameters.get("id", as: PeopleEvent.IDValue.self) else {
            throw Abort(.badRequest)
        }

        return PeopleEvent.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
    }

    func updateEventByID(req: Request) throws -> EventLoopFuture<PeopleEvent> {
        guard let id = req.parameters.get("id", as: PeopleEvent.IDValue.self) else {
            throw Abort(.badRequest)
        }

        let dto = try req.content.decode(PeopleEventUpdateDTO.self)

        return PeopleEvent.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { existing in
                if let value = dto.title { existing.title = value }
                if let value = dto.subtitle { existing.subtitle = value }
                if let value = dto.text { existing.text = value }
                if let value = dto.image { existing.image = value }
                if let value = dto.location { existing.location = value }
                if let value = dto.startDate { existing.startDate = value }
                if let value = dto.endDate { existing.endDate = value }
                if let value = dto.maxCapacity { existing.maxCapacity = value }
                if let value = dto.isRegistrationOpen { existing.isRegistrationOpen = value }
                if let value = dto.registrationDeadline { existing.registrationDeadline = value }
                if let value = dto.tag { existing.tag = value }

                return existing.update(on: req.db).map { existing }
            }
    }

    func deleteEventByID(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let id = req.parameters.get("id", as: PeopleEvent.IDValue.self) else {
            throw Abort(.badRequest)
        }

        return PeopleEvent.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { event in
                event.delete(on: req.db).transform(to: .ok)
            }
    }

    // MARK: - Guests

    func addGuestToEvent(req: Request) throws -> EventLoopFuture<PeopleEventGuestResponseDTO> {
        guard let eventID = req.parameters.get("id", as: PeopleEvent.IDValue.self) else {
            throw Abort(.badRequest)
        }

        let dto = try req.content.decode(PeopleEventGuestCreateDTO.self)

        guard !dto.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Name is required.")
        }

        let requestedPeople = dto.numberOfPeople ?? 1

        guard requestedPeople > 0 else {
            throw Abort(.badRequest, reason: "Number of people must be at least 1.")
        }

        return PeopleEvent.find(eventID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { event in
                do {
                    try self.validateRegistrationIsPossible(event: event)
                } catch {
                    return req.eventLoop.makeFailedFuture(error)
                }

                return self.currentReservedPeople(for: eventID, req: req)
                    .flatMap { currentReservedPeople in
                        if let maxCapacity = event.maxCapacity,
                           currentReservedPeople + requestedPeople > maxCapacity {
                            return req.eventLoop.makeFailedFuture(
                                Abort(.badRequest, reason: "Event capacity exceeded.")
                            )
                        }

                        let guest = dto.toModel(eventID: eventID)

                        return guest.save(on: req.db)
                            .map { PeopleEventGuestResponseDTO(from: guest) }
                    }
            }
    }

    func getGuestsForEvent(req: Request) throws -> EventLoopFuture<[PeopleEventGuestResponseDTO]> {
        guard let eventID = req.parameters.get("id", as: PeopleEvent.IDValue.self) else {
            throw Abort(.badRequest)
        }

        return PeopleEventGuest.query(on: req.db)
            .filter(\.$event.$id == eventID)
            .sort(\.$created, .descending)
            .all()
            .map { guests in
                guests.map { PeopleEventGuestResponseDTO(from: $0) }
            }
    }

    func getGuestByID(req: Request) throws -> EventLoopFuture<PeopleEventGuestResponseDTO> {
        guard let eventID = req.parameters.get("id", as: PeopleEvent.IDValue.self),
              let guestID = req.parameters.get("guestID", as: PeopleEventGuest.IDValue.self) else {
            throw Abort(.badRequest)
        }

        return PeopleEventGuest.query(on: req.db)
            .filter(\.$id == guestID)
            .filter(\.$event.$id == eventID)
            .first()
            .unwrap(or: Abort(.notFound))
            .map { PeopleEventGuestResponseDTO(from: $0) }
    }

    func updateGuestByID(req: Request) throws -> EventLoopFuture<PeopleEventGuestResponseDTO> {
        guard let eventID = req.parameters.get("id", as: PeopleEvent.IDValue.self),
              let guestID = req.parameters.get("guestID", as: PeopleEventGuest.IDValue.self) else {
            throw Abort(.badRequest)
        }

        let dto = try req.content.decode(PeopleEventGuestUpdateDTO.self)

        if let numberOfPeople = dto.numberOfPeople, numberOfPeople <= 0 {
            throw Abort(.badRequest, reason: "Number of people must be at least 1.")
        }

        return PeopleEventGuest.query(on: req.db)
            .filter(\.$id == guestID)
            .filter(\.$event.$id == eventID)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { existing in
                let oldPeopleCount = existing.numberOfPeople ?? 1
                let newPeopleCount = dto.numberOfPeople ?? oldPeopleCount
                let newStatus = dto.status ?? existing.status
                let shouldCountReservation = newStatus != "cancelled"

                return PeopleEvent.find(eventID, on: req.db)
                    .unwrap(or: Abort(.notFound))
                    .flatMap { event in
                        self.currentReservedPeople(for: eventID, req: req)
                            .flatMap { currentReservedPeople in
                                let adjustedPeopleCount: Int

                                if shouldCountReservation {
                                    adjustedPeopleCount = currentReservedPeople - oldPeopleCount + newPeopleCount
                                } else {
                                    adjustedPeopleCount = currentReservedPeople - oldPeopleCount
                                }

                                if let maxCapacity = event.maxCapacity,
                                   adjustedPeopleCount > maxCapacity {
                                    return req.eventLoop.makeFailedFuture(
                                        Abort(.badRequest, reason: "Event capacity exceeded.")
                                    )
                                }

                                if let value = dto.name { existing.name = value }
                                if let value = dto.team { existing.team = value }
                                if let value = dto.email { existing.email = value }
                                if let value = dto.phone { existing.phone = value }
                                if let value = dto.numberOfPeople { existing.numberOfPeople = value }
                                if let value = dto.additionalGuestNames { existing.additionalGuestNames = value }
                                if let value = dto.status { existing.status = value }
                                if let value = dto.notes { existing.notes = value }

                                return existing.update(on: req.db)
                                    .map { PeopleEventGuestResponseDTO(from: existing) }
                            }
                    }
            }
    }

    func deleteGuestFromEvent(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let eventID = req.parameters.get("id", as: PeopleEvent.IDValue.self),
              let guestID = req.parameters.get("guestID", as: PeopleEventGuest.IDValue.self) else {
            throw Abort(.badRequest)
        }

        return PeopleEventGuest.query(on: req.db)
            .filter(\.$id == guestID)
            .filter(\.$event.$id == eventID)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { guest in
                guest.delete(on: req.db).transform(to: .ok)
            }
    }

    // MARK: - Summary

    func getEventSummary(req: Request) throws -> EventLoopFuture<PeopleEventSummaryDTO> {
        guard let eventID = req.parameters.get("id", as: PeopleEvent.IDValue.self) else {
            throw Abort(.badRequest)
        }

        return PeopleEvent.find(eventID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { event in
                PeopleEventGuest.query(on: req.db)
                    .filter(\.$event.$id == eventID)
                    .sort(\.$created, .descending)
                    .all()
                    .map { guests in
                        let activeGuests = guests.filter { $0.status != "cancelled" }
                        let registeredPeople = activeGuests.reduce(0) { result, guest in
                            result + (guest.numberOfPeople ?? 1)
                        }

                        return PeopleEventSummaryDTO(
                            event: PeopleEventResponseDTO(
                                from: event,
                                registeredGuests: activeGuests.count,
                                registeredPeople: registeredPeople
                            ),
                            guests: guests.map { PeopleEventGuestResponseDTO(from: $0) }
                        )
                    }
            }
    }

    func getAllEventsWithCounts(req: Request) throws -> EventLoopFuture<[PeopleEventResponseDTO]> {
        return PeopleEvent.query(on: req.db)
            .sort(\.$created, .descending)
            .all()
            .flatMap { events in
                let futures = events.map { event -> EventLoopFuture<PeopleEventResponseDTO> in
                    guard let eventID = event.id else {
                        return req.eventLoop.makeSucceededFuture(
                            PeopleEventResponseDTO(from: event)
                        )
                    }

                    return PeopleEventGuest.query(on: req.db)
                        .filter(\.$event.$id == eventID)
                        .all()
                        .map { guests in
                            let activeGuests = guests.filter { $0.status != "cancelled" }
                            let registeredPeople = activeGuests.reduce(0) { result, guest in
                                result + (guest.numberOfPeople ?? 1)
                            }

                            return PeopleEventResponseDTO(
                                from: event,
                                registeredGuests: activeGuests.count,
                                registeredPeople: registeredPeople
                            )
                        }
                }

                return EventLoopFuture.whenAllSucceed(futures, on: req.eventLoop)
            }
    }

    // MARK: - Open / Close Registration

    func openRegistration(req: Request) throws -> EventLoopFuture<PeopleEvent> {
        guard let eventID = req.parameters.get("id", as: PeopleEvent.IDValue.self) else {
            throw Abort(.badRequest)
        }

        return PeopleEvent.find(eventID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { event in
                event.isRegistrationOpen = true
                return event.update(on: req.db).map { event }
            }
    }

    func closeRegistration(req: Request) throws -> EventLoopFuture<PeopleEvent> {
        guard let eventID = req.parameters.get("id", as: PeopleEvent.IDValue.self) else {
            throw Abort(.badRequest)
        }

        return PeopleEvent.find(eventID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { event in
                event.isRegistrationOpen = false
                return event.update(on: req.db).map { event }
            }
    }

    // MARK: - Helpers

    private func validateRegistrationIsPossible(event: PeopleEvent) throws {
        if event.isRegistrationOpen == false {
            throw Abort(.badRequest, reason: "Registration is closed for this event.")
        }

        if let registrationDeadline = event.registrationDeadline,
           Date.viennaNow > registrationDeadline {
            throw Abort(.badRequest, reason: "Registration deadline has passed.")
        }
    }

    private func currentReservedPeople(
        for eventID: PeopleEvent.IDValue,
        req: Request
    ) -> EventLoopFuture<Int> {
        PeopleEventGuest.query(on: req.db)
            .filter(\.$event.$id == eventID)
            .all()
            .map { guests in
                guests
                    .filter { $0.status != "cancelled" }
                    .reduce(0) { result, guest in
                        result + (guest.numberOfPeople ?? 1)
                    }
            }
    }
}

// MARK: - Summary DTO

struct PeopleEventSummaryDTO: Content {
    var event: PeopleEventResponseDTO
    var guests: [PeopleEventGuestResponseDTO]
}
