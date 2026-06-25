import Vapor

enum OpenAPISupport {
    static func registerRoutes(on app: Application) {
        registerRoutes(on: app, documentPath: "/openapi.yaml")
    }

    private static func registerRoutes(on routes: RoutesBuilder, documentPath: String) {
        routes.get("openapi.yaml") { req -> Response in
            let yaml = makeDocument(for: req.application)
            var headers = HTTPHeaders()
            headers.contentType = .init(type: "application", subType: "yaml", parameters: [:])
            return Response(status: .ok, headers: headers, body: .init(string: yaml))
        }

        routes.get("docs") { _ -> Response in
            var headers = HTTPHeaders()
            headers.contentType = .html
            return Response(status: .ok, headers: headers, body: .init(string: swaggerHTML(documentPath: documentPath)))
        }
    }

    static func makeDocument(for app: Application) -> String {
        let operations = app.routes.all
            .compactMap(RouteOperation.init(route:))
            .filter { operation in
                !operation.path.hasPrefix("/docs")
                    && !operation.path.hasPrefix("/openapi")
            }
            .sorted()

        let tags = Array(Set(operations.map(\.tag))).sorted()

        var lines: [String] = [
            "openapi: 3.1.0",
            "info:",
            "  title: OEKFB Backend API",
            "  version: 1.0.0",
            "servers:",
            "  - url: /"
        ]

        if !tags.isEmpty {
            lines.append("tags:")
            for tag in tags {
                lines.append("  - name: \(quoted(tag))")
                lines.append("    description: \(quoted(description(for: tag)))")
            }
        }

        lines.append(contentsOf: [
            "paths:"
        ])

        var currentPath: String?
        for operation in operations {
            if currentPath != operation.path {
                lines.append("  \(quoted(operation.path)):")
                currentPath = operation.path
            }

            lines.append("    \(operation.method):")
            lines.append("      operationId: \(operation.operationID)")
            lines.append("      summary: \(quoted(operation.summary))")
            lines.append("      tags:")
            lines.append("        - \(quoted(operation.tag))")

            if let security = operation.securityRequirement {
                lines.append("      security:")
                lines.append("        - \(security): []")
            }

            if !operation.parameters.isEmpty {
                lines.append("      parameters:")
                for parameter in operation.parameters {
                    lines.append("        - name: \(parameter)")
                    lines.append("          in: path")
                    lines.append("          required: true")
                    lines.append("          schema:")
                    lines.append("            type: string")
                }
            }

            if operation.supportsRequestBody {
                lines.append("      requestBody:")
                lines.append("        required: false")
                lines.append("        content:")
                lines.append("          application/json:")
                lines.append("            schema:")
                lines.append("              type: object")
                lines.append("              additionalProperties: true")
            }

            lines.append("      responses:")
            lines.append("        '200':")
            lines.append("          description: Successful response")
            lines.append("          content:")
            lines.append("            application/json:")
            lines.append("              schema:")
            lines.append("                type: object")
            lines.append("                additionalProperties: true")
            lines.append("        '201':")
            lines.append("          description: Created")
            lines.append("        '204':")
            lines.append("          description: No content")
            lines.append("        '400':")
            lines.append("          description: Bad request")
            lines.append("        '401':")
            lines.append("          description: Unauthorized")
            lines.append("        '403':")
            lines.append("          description: Forbidden")
            lines.append("        '404':")
            lines.append("          description: Not found")
        }

        lines.append(contentsOf: [
            "components:",
            "  securitySchemes:",
            "    bearerAuth:",
            "      type: http",
            "      scheme: bearer",
            "    basicAuth:",
            "      type: http",
            "      scheme: basic"
        ])

        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func description(for tag: String) -> String {
        switch tag {
        case let value where value.hasPrefix("Admin /"):
            return "Admin-only management endpoints."
        case let value where value.hasPrefix("Mobile App /"):
            return "Endpoints used by the mobile app experience."
        case let value where value.hasPrefix("Core /"):
            return "Shared resource endpoints."
        case "Web Client":
            return "Endpoints used by the web client."
        case "Public Client":
            return "Public client-facing endpoints."
        case "Guest List":
            return "People event and guest registration endpoints."
        case "Documentation":
            return "API documentation endpoints."
        case "Email":
            return "Email utility endpoints."
        case "Scraper":
            return "Data scraping endpoints."
        case "System":
            return "Health and utility endpoints."
        default:
            return "Application endpoints."
        }
    }

    private static func swaggerHTML(documentPath: String) -> String {
        """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>OEKFB Backend API Docs</title>
      <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
      <style>
        body { margin: 0; background: #f7f7f7; }
        .swagger-ui .topbar { display: none; }
      </style>
    </head>
    <body>
      <div id="swagger-ui"></div>
      <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
      <script>
        window.ui = SwaggerUIBundle({
          url: '\(documentPath)',
          dom_id: '#swagger-ui',
          deepLinking: true,
          displayRequestDuration: true,
          tryItOutEnabled: true,
          defaultModelsExpandDepth: 1,
          tagsSorter: 'alpha',
          operationsSorter: 'method'
        });
      </script>
    </body>
    </html>
    """
    }
}

private struct RouteOperation: Comparable {
    let method: String
    let path: String
    let parameters: [String]
    let operationID: String
    let summary: String
    let tag: String
    let securityRequirement: String?

    var supportsRequestBody: Bool {
        ["post", "put", "patch"].contains(method)
    }

    init?(route: Route) {
        let method = route.method.string.lowercased()
        guard Self.openAPIMethods.contains(method) else {
            return nil
        }

        self.method = method
        let components = route.path.map { String(describing: $0) }
        self.path = "/" + components.map(Self.openapiPathComponent).joined(separator: "/")
        self.parameters = components.compactMap(Self.parameterName)
        self.tag = Self.tagName(components: components)
        self.operationID = Self.operationID(method: method, components: components)
        self.summary = Self.summary(method: method, components: components)
        self.securityRequirement = Self.securityRequirement(components: components)
    }

    static func < (lhs: RouteOperation, rhs: RouteOperation) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.method < rhs.method
    }

    private static let openAPIMethods: Set<String> = [
        "get", "post", "put", "patch", "delete", "options", "head", "trace"
    ]

    private static let coreResources: Set<String> = [
        "chat",
        "events",
        "finanzen",
        "leagues",
        "matches",
        "news",
        "players",
        "postpone",
        "referees",
        "registrations",
        "seasons",
        "sponsor",
        "stadiums",
        "strafsenat",
        "teams",
        "transfers",
        "transferSettings",
        "users"
    ]

    private static func openapiPathComponent(_ component: String) -> String {
        if let parameter = parameterName(component) {
            return "{\(parameter)}"
        }
        if component == "**" || component == "*" {
            return "{catchall}"
        }
        return component
    }

    private static func parameterName(_ component: String) -> String? {
        guard component.hasPrefix(":") else {
            return nil
        }
        return String(component.dropFirst())
    }

    private static func tagName(components: [String]) -> String {
        guard let first = components.first else {
            return "System"
        }

        switch first {
        case "admin":
            return groupedTag(prefix: "Admin", component: components.dropFirst().first ?? "root")
        case "app":
            return groupedTag(prefix: "Mobile App", component: components.dropFirst().first ?? "root")
        case "client":
            return "Public Client"
        case "webClient":
            return "Web Client"
        case "people-events":
            return "Guest List"
        case "sendTestEmail":
            return "Email"
        case "scraper":
            return "Scraper"
        case "docs", "openapi.yaml":
            return "Documentation"
        case "status":
            return "System"
        case let resource where coreResources.contains(resource):
            return groupedTag(prefix: "Core", component: resource)
        default:
            return title(first)
        }
    }

    private static func groupedTag(prefix: String, component: String) -> String {
        "\(prefix) / \(title(parameterName(component) ?? component))"
    }

    private static func title(_ value: String) -> String {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0.lowercased().capitalized }
            .joined(separator: " ")
    }

    private static func operationID(method: String, components: [String]) -> String {
        let parts = ([method] + components).map { component -> String in
            let raw = parameterName(component) ?? component
            return raw
                .split { !$0.isLetter && !$0.isNumber }
                .map { $0.lowercased().capitalized }
                .joined()
        }

        let id = parts.joined()
        guard let first = id.first else {
            return method
        }
        return first.lowercased() + id.dropFirst()
    }

    private static func summary(method: String, components: [String]) -> String {
        let routeName = components
            .map { parameterName($0).map { "{\($0)}" } ?? title($0) }
            .joined(separator: " ")
        return "\(method.uppercased()) \(routeName.isEmpty ? "/" : routeName)"
    }

    private static func securityRequirement(components: [String]) -> String? {
        guard let first = components.first else {
            return nil
        }

        if first == "admin" {
            if components.dropFirst().prefix(2).elementsEqual(["auth", "login"]) {
                return "basicAuth"
            }
            return "bearerAuth"
        }

        if first == "app", components.dropFirst().prefix(2).elementsEqual(["auth", "login"]) {
            return "basicAuth"
        }

        return nil
    }
}
