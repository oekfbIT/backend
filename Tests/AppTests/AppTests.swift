@testable import App
import XCTVapor

final class AppTests: XCTestCase {
    func testOpenAPIDocumentIncludesRegisteredRoutes() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        try routes(app)
        OpenAPISupport.registerRoutes(on: app)

        try app.test(.GET, "openapi.yaml", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)

            let body = res.body.string
            XCTAssertTrue(body.contains("openapi: 3.1.0"))
            XCTAssertTrue(body.contains("title: OEKFB Backend API"))
            XCTAssertTrue(body.contains("'/status':"))
            XCTAssertTrue(body.contains("'/admin/auth/login':"))
            XCTAssertTrue(body.contains("'/app/auth/login':"))
            XCTAssertTrue(body.contains("'/people-events/{id}/guests/{guestID}':"))
            XCTAssertTrue(body.contains("name: 'Admin / Auth'"))
            XCTAssertTrue(body.contains("name: 'Mobile App / Auth'"))
            XCTAssertTrue(body.contains("name: 'Guest List'"))
            XCTAssertTrue(body.contains("bearerAuth:"))
            XCTAssertTrue(body.contains("basicAuth:"))
        })
    }

    func testSwaggerDocsAreServed() async throws {
        let app = Application(.testing)
        defer { app.shutdown() }
        OpenAPISupport.registerRoutes(on: app)

        try app.test(.GET, "docs", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("SwaggerUIBundle"))
            XCTAssertTrue(res.body.string.contains("/openapi.yaml"))
        })
    }
}
