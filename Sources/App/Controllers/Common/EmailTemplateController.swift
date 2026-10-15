import Fluent
import Vapor

struct EmailTemplateController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let root = routes.grouped("admin", "email-templates").grouped(PermissionMiddleware(.communicationsManage))
        root.get(use: list)
        root.on(.PUT, ":key", body: .collect(maxSize: "1mb"), use: save)
        root.delete(":key", use: reset)
        root.on(.POST, ":key", "preview", body: .collect(maxSize: "1mb"), use: preview)
    }

    struct Item: Content {
        let key: String
        let subject: String
        let html: String
        let variables: [String]
        let customized: Bool
    }

    func list(req: Request) async throws -> [Item] {
        let stored = try await StoredMailTemplate.query(on: req.db).all()
        var items: [Item] = []
        for definition in EmailTemplateCatalog.all {
            let saved = stored.first { $0.id == definition.key }
            let content = try await EmailTemplateService.content(key: definition.key, on: req.db)
            items.append(Item(key: definition.key, subject: content.subject,
                              html: content.html, variables: definition.variables, customized: saved != nil))
        }
        return items
    }

    func save(req: Request) async throws -> HTTPStatus {
        let definition = try EmailTemplateCatalog.definition(req.parameters.get("key") ?? "")
        let edit = try req.content.decode(MailTemplateEdit.self)
        try EmailTemplateService.validate(edit, definition: definition)
        if let record = try await StoredMailTemplate.find(definition.key, on: req.db) {
            record.subject = edit.subject; record.html = edit.html
            try await record.update(on: req.db)
        } else {
            try await StoredMailTemplate(key: definition.key, subject: edit.subject, html: edit.html).create(on: req.db)
        }
        return .noContent
    }

    func reset(req: Request) async throws -> HTTPStatus {
        let definition = try EmailTemplateCatalog.definition(req.parameters.get("key") ?? "")
        if let record = try await StoredMailTemplate.find(definition.key, on: req.db) {
            try await record.delete(on: req.db)
        }
        return .noContent
    }

    func preview(req: Request) throws -> RenderedMailTemplate {
        let definition = try EmailTemplateCatalog.definition(req.parameters.get("key") ?? "")
        let edit = try req.content.decode(MailTemplateEdit.self)
        let samples = Dictionary(uniqueKeysWithValues: definition.variables.map { name in
            (name, name.lowercased().contains("url") ? "https://example.com/vorschau" : "Beispiel: \(name)")
        })
        return try EmailTemplateService.render(edit, definition: definition, values: samples)
    }
}
