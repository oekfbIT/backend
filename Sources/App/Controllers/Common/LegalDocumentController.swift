import Foundation
import Fluent
import Vapor

final class LegalDocumentController: RouteCollection {
    let path: String

    init(path: String) {
        self.path = path
    }

    func boot(routes: RoutesBuilder) throws {
        routes.grouped(PathComponent(stringLiteral: path))
            .get(":document", use: getDocument)
    }

    func getDocument(req: Request) async throws -> LegalDocumentResponse {
        let document = try LegalDocumentSupport.documentType(from: req)
        return try await LegalDocumentSupport.response(for: document, on: req.db)
    }
}

struct LegalSectionResponse: Content {
    let id: UUID
    let documentType: LegalDocumentType
    let position: Int
    let heading: String
    let title: String
    let content: String
    let updatedAt: Date?
}

struct LegalDocumentResponse: Content {
    let documentType: LegalDocumentType
    let updatedAt: Date?
    let sections: [LegalSectionResponse]
}

enum LegalDocumentSupport {
    static func documentType(from req: Request) throws -> LegalDocumentType {
        let rawValue = try req.parameters.require("document")
        guard let document = LegalDocumentType(rawValue: rawValue) else {
            throw Abort(
                .badRequest,
                reason: "Unknown document. Use regeln, ligaordnung, or bund."
            )
        }
        return document
    }

    static func sections(
        for document: LegalDocumentType,
        on database: Database
    ) async throws -> [LegalSection] {
        try await LegalSection.query(on: database)
            .filter(\.$documentType == document)
            .sort(\.$position, .ascending)
            .all()
    }

    static func response(
        for document: LegalDocumentType,
        on database: Database
    ) async throws -> LegalDocumentResponse {
        let items = try await sections(for: document, on: database)
        let sections = try items.map { item -> LegalSectionResponse in
            let id = try item.requireID()
            let title = document.usesParagraphNumbers
                ? "§ \(item.position) – \(item.heading)"
                : item.heading

            return LegalSectionResponse(
                id: id,
                documentType: item.documentType,
                position: item.position,
                heading: item.heading,
                title: title,
                content: item.content,
                updatedAt: item.updatedAt ?? item.createdAt
            )
        }

        return LegalDocumentResponse(
            documentType: document,
            updatedAt: sections.compactMap(\.updatedAt).max(),
            sections: sections
        )
    }

    static func normalizedHeading(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Heading must not be empty.")
        }

        let pattern = #"^§\s*\d+\s*[–—-]\s*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let heading = expression
            .stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.isEmpty ? trimmed : heading
    }

    static func validateContent(_ value: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Content must not be empty.")
        }
        return value
    }

    static func persistCanonicalOrder(
        _ sections: [LegalSection],
        on database: Database
    ) async throws {
        for (index, section) in sections.enumerated() {
            let expectedPosition = index + 1
            if section.position != expectedPosition {
                section.position = expectedPosition
                try await section.update(on: database)
            }
        }
    }
}
