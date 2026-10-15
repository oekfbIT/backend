import XCTest
@testable import App

final class EmailTemplateTests: XCTestCase {
    func testEveryDefaultRendersWithoutUnresolvedPlaceholders() throws {
        for definition in EmailTemplateCatalog.all {
            let values = Dictionary(uniqueKeysWithValues: definition.variables.map { ($0, "Example") })
            let result = try EmailTemplateService.render(.init(subject: definition.subject, html: definition.html), definition: definition, values: values)
            XCTAssertFalse(result.html.contains("{{"), definition.key)
            XCTAssertFalse(result.subject.contains("{{"), definition.key)
        }
    }

    func testEscapingAndSinglePassReplacement() throws {
        let definition = MailTemplateDefinition(key: "test", subject: "{{name}}", html: "<p>{{ name }}</p>", variables: ["name"])
        let result = try EmailTemplateService.render(.init(subject: definition.subject, html: definition.html), definition: definition,
            values: ["name": "<script>\"&'{{name}}\r\n"])
        XCTAssertTrue(result.html.contains("&lt;script&gt;&quot;&amp;&#39;{{name}}"))
        XCTAssertFalse(result.subject.contains("\n"))
    }

    func testInvalidAndMissingVariablesAreRejected() throws {
        let definition = try EmailTemplateCatalog.definition("sendEmailVerificationLink")
        for html in ["<p>{{unknown}}</p>", "<p>{{verificationUrl</p>", "<p>Link removed</p>"] {
            XCTAssertThrowsError(try EmailTemplateService.validate(.init(subject: "Test", html: html), definition: definition))
        }
        XCTAssertThrowsError(try EmailTemplateService.render(.init(subject: definition.subject, html: definition.html), definition: definition, values: [:]))
        XCTAssertThrowsError(try EmailTemplateService.validate(.init(subject: "Injected\r\nBcc: other@example.com", html: definition.html), definition: definition))
    }
}

import XCTVapor

private struct TemplateTestLogin: Middleware {
    let permissions: [UserPermission]
    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        let user = User(userID: "test", type: .admin, firstName: "Test", lastName: "Admin", email: "test@example.com", passwordHash: "unused")
        user.permissions = permissions
        request.auth.login(user)
        return next.respond(to: request)
    }
}

extension EmailTemplateTests {
    func testEndpointsRequireCommunicationPermission() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try EmailTemplateController().boot(routes: app.grouped(TemplateTestLogin(permissions: [])))
        for method: HTTPMethod in [.GET, .PUT, .DELETE, .POST] {
            let path = method == .GET ? "admin/email-templates" : "admin/email-templates/sendWelcomeMail" + (method == .POST ? "/preview" : "")
            try app.test(method, path) { response in XCTAssertEqual(response.status, .forbidden) }
        }
    }

    func testPreviewUsesSampleValuesWithoutSendingEmail() throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try EmailTemplateController().boot(routes: app.grouped(TemplateTestLogin(permissions: [.communicationsManage])))
        try app.test(.POST, "admin/email-templates/sendEmailVerificationLink/preview", beforeRequest: { request in
            try request.content.encode(MailTemplateEdit(subject: "Vorschau", html: "<a href=\"{{verificationUrl}}\">Bestätigen</a>"))
        }, afterResponse: { response in
            XCTAssertEqual(response.status, .ok)
            let rendered = try response.content.decode(RenderedMailTemplate.self)
            XCTAssertTrue(rendered.html.contains("https://example.com/vorschau"))
            XCTAssertFalse(rendered.html.contains("{{"))
        })
    }
}
