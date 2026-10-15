import Fluent
import Vapor

final class StoredMailTemplate: Model, @unchecked Sendable {
    static let schema = "email_templates"
    @ID(custom: "_id", generatedBy: .user) var id: String?
    @Field(key: "subject") var subject: String
    @Field(key: "html") var html: String
    init() {}
    init(key: String, subject: String, html: String) {
        self.id = key; self.subject = subject; self.html = html
    }
}

struct MailTemplateEdit: Content {
    let subject: String
    let html: String
}

struct RenderedMailTemplate: Content {
    let subject: String
    let html: String
}

enum EmailTemplateService {
    static let expression = try! NSRegularExpression(pattern: #"\{\{\s*([a-zA-Z][a-zA-Z0-9]*)\s*\}\}"#)

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func validate(_ edit: MailTemplateEdit, definition: MailTemplateDefinition) throws {
        guard !edit.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              edit.subject.utf8.count <= 500, edit.subject.rangeOfCharacter(from: .newlines) == nil,
              !edit.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              edit.html.utf8.count <= 200_000 else {
            throw Abort(.badRequest, reason: "Betreff (max. 500 Zeichen) und HTML (max. 200 KB) sind erforderlich; der Betreff darf keine Zeilenumbrüche enthalten.")
        }
        for source in [edit.subject, edit.html] {
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                let name = String(source[Range(match.range(at: 1), in: source)!])
                guard definition.variables.contains(name) else {
                    throw Abort(.badRequest, reason: "Unbekannte Variable: {{\(name)}}")
                }
            }
            let remaining = expression.stringByReplacingMatches(in: source, range: range, withTemplate: "")
            guard !remaining.contains("{{"), !remaining.contains("}}") else {
                throw Abort(.badRequest, reason: "Variablen bitte als {{variableName}} schreiben.")
            }
        }
        // Action links and credentials must survive a copy edit.
        var required = definition.variables.filter { ["verificationUrl", "uploadUrl", "contractUrl", "actionUrl", "password"].contains($0) }
        if definition.key == "sendPaymentMail" { required += ["amount", "deposit", "teamName"] }
        if definition.key == "sendTeamLogin" { required += ["email"] }
        let matches = expression.matches(in: edit.html, range: NSRange(edit.html.startIndex..., in: edit.html))
        let used = Set(matches.map { String(edit.html[Range($0.range(at: 1), in: edit.html)!]) })
        guard Set(required).isSubset(of: used) else {
            throw Abort(.badRequest, reason: "Erforderliche Variablen fehlen: \(required.filter { !used.contains($0) }.joined(separator: ", "))")
        }
    }

    static func render(_ edit: MailTemplateEdit, definition: MailTemplateDefinition, values: [String: String]) throws -> RenderedMailTemplate {
        try validate(edit, definition: definition)
        func replace(_ source: String, html: Bool) throws -> String {
            var result = source
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
                let name = String(source[Range(match.range(at: 1), in: source)!])
                guard let value = values[name] else { throw Abort(.internalServerError, reason: "Fehlender E-Mail-Wert: \(name)") }
                result.replaceSubrange(Range(match.range, in: result)!, with: html ? escape(value) : value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
            }
            return result
        }
        return try .init(subject: replace(edit.subject, html: false), html: replace(edit.html, html: true))
    }

    static func content(key: String, on db: Database) async throws -> MailTemplateEdit {
        let definition = try EmailTemplateCatalog.definition(key)
        if let saved = try await StoredMailTemplate.find(key, on: db) {
            let edit = MailTemplateEdit(subject: saved.subject, html: saved.html)
            // Older saved welcome templates predate the mandatory upload links.
            // Use the current default until the administrator updates that override.
            if ["sendWelcomeMail", "sendPaymentMail", "sendTeamLogin"].contains(key), (try? validate(edit, definition: definition)) == nil {
                return .init(subject: definition.subject, html: definition.html)
            }
            return edit
        }
        return .init(subject: definition.subject, html: definition.html)
    }

    static func render(key: String, values: [String: String], on db: Database) async throws -> RenderedMailTemplate {
        try await render(content(key: key, on: db), definition: EmailTemplateCatalog.definition(key), values: values)
    }
}
