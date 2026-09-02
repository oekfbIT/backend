import Fluent
import Vapor

extension AdminController {
    func setupLegalReadRoutes(on root: RoutesBuilder) {
        let legal = root.grouped("legal")

        legal.get(":document", use: getLegalDocument)
    }

    func setupLegalWriteRoutes(on root: RoutesBuilder) {
        let legal = root.grouped("legal")

        legal.post(":document", use: createLegalSection)
        legal.patch(":document", ":id", use: updateLegalSection)
        legal.delete(":document", ":id", use: deleteLegalSection)
        legal.put(":document", "order", use: reorderLegalSections)
    }
}

extension AdminController {
    struct CreateLegalSectionRequest: Content {
        let heading: String
        let content: String
        let position: Int?
    }

    struct UpdateLegalSectionRequest: Content {
        let heading: String?
        let content: String?
        let position: Int?
    }

    struct ReorderLegalSectionsRequest: Content {
        let sectionIds: [UUID]
    }

    func getLegalDocument(req: Request) async throws -> LegalDocumentResponse {
        let document = try LegalDocumentSupport.documentType(from: req)
        return try await LegalDocumentSupport.response(for: document, on: req.db)
    }

    func createLegalSection(req: Request) async throws -> LegalDocumentResponse {
        let document = try LegalDocumentSupport.documentType(from: req)
        let body = try req.content.decode(CreateLegalSectionRequest.self)
        var sections = try await LegalDocumentSupport.sections(for: document, on: req.db)

        let section = LegalSection(
            documentType: document,
            heading: try LegalDocumentSupport.normalizedHeading(body.heading),
            content: try LegalDocumentSupport.validateContent(body.content),
            position: sections.count + 1
        )
        try await section.create(on: req.db)

        let targetIndex = min(max((body.position ?? sections.count + 1) - 1, 0), sections.count)
        sections.insert(section, at: targetIndex)
        try await LegalDocumentSupport.persistCanonicalOrder(sections, on: req.db)
        return try await LegalDocumentSupport.response(for: document, on: req.db)
    }

    func updateLegalSection(req: Request) async throws -> LegalDocumentResponse {
        let document = try LegalDocumentSupport.documentType(from: req)
        let id = try req.parameters.require("id", as: UUID.self)
        let body = try req.content.decode(UpdateLegalSectionRequest.self)
        var sections = try await LegalDocumentSupport.sections(for: document, on: req.db)

        guard let currentIndex = sections.firstIndex(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "Legal section not found.")
        }

        let section = sections[currentIndex]
        if let heading = body.heading {
            section.heading = try LegalDocumentSupport.normalizedHeading(heading)
        }
        if let content = body.content {
            section.content = try LegalDocumentSupport.validateContent(content)
        }
        try await section.update(on: req.db)

        if let requestedPosition = body.position {
            sections.remove(at: currentIndex)
            let targetIndex = min(max(requestedPosition - 1, 0), sections.count)
            sections.insert(section, at: targetIndex)
        }
        try await LegalDocumentSupport.persistCanonicalOrder(sections, on: req.db)
        return try await LegalDocumentSupport.response(for: document, on: req.db)
    }

    func deleteLegalSection(req: Request) async throws -> LegalDocumentResponse {
        let document = try LegalDocumentSupport.documentType(from: req)
        let id = try req.parameters.require("id", as: UUID.self)
        var sections = try await LegalDocumentSupport.sections(for: document, on: req.db)

        guard let index = sections.firstIndex(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "Legal section not found.")
        }
        let section = sections.remove(at: index)
        try await section.delete(on: req.db)
        try await LegalDocumentSupport.persistCanonicalOrder(sections, on: req.db)
        return try await LegalDocumentSupport.response(for: document, on: req.db)
    }

    func reorderLegalSections(req: Request) async throws -> LegalDocumentResponse {
        let document = try LegalDocumentSupport.documentType(from: req)
        let body = try req.content.decode(ReorderLegalSectionsRequest.self)
        let sections = try await LegalDocumentSupport.sections(for: document, on: req.db)

        let existingByID = Dictionary(uniqueKeysWithValues: try sections.map {
            (try $0.requireID(), $0)
        })
        guard body.sectionIds.count == sections.count,
              Set(body.sectionIds).count == sections.count,
              body.sectionIds.allSatisfy({ existingByID[$0] != nil }) else {
            throw Abort(
                .badRequest,
                reason: "section_ids must contain every section exactly once."
            )
        }

        let ordered = body.sectionIds.compactMap { existingByID[$0] }
        try await LegalDocumentSupport.persistCanonicalOrder(ordered, on: req.db)
        return try await LegalDocumentSupport.response(for: document, on: req.db)
    }
}
