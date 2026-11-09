import Foundation
import Fluent
import Vapor

extension AdminController {
    struct GenerateJerseyKitRequest: Content { let image: File }
    struct SaveTeamJerseyRequest: Content {
        let image: File
        let expectedImageUrl: String
    }
    struct SaveTeamJerseyResponse: Content {
        let side: String
        let imageUrl: String
    }
    enum JerseySide: String { case home, away }

    func setupJerseyKitRoutes(on root: RoutesBuilder) {
        root.on(.POST, "jersey-kits", "generate", body: .collect(maxSize: "11mb"), use: generateJerseyKit)
        root.on(.PUT, "teams", ":id", "jerseys", ":side", body: .collect(maxSize: "21mb"), use: saveTeamJersey)
    }

    // No team lookup, storage, or assignment during generation.
    func generateJerseyKit(req: Request) async throws -> Response {
        let input = try req.content.decode(GenerateJerseyKitRequest.self)
        let image = try await req.application.jerseyKitGenerator.generate(image: input.image)
        return Response(status: .ok, headers: [
            "Content-Type": "image/png", "Cache-Control": "no-store",
            "Content-Disposition": "inline; filename=generated-kit.png"
        ], body: .init(buffer: image.data))
    }

    // Called only after the client approves a generated image or explicitly saves an original.
    func saveTeamJersey(req: Request) async throws -> SaveTeamJerseyResponse {
        let id = try req.parameters.require("id", as: UUID.self)
        guard let rawSide = req.parameters.get("side"), let side = JerseySide(rawValue: rawSide) else {
            throw Abort(.badRequest, reason: "Jersey side must be home or away.")
        }
        let input = try req.content.decode(SaveTeamJerseyRequest.self)
        // Generated PNGs can exceed the 10 MiB input-photo limit.
        try UploadValidation.validate(input.image, allowed: [.png, .jpeg], maximumBytes: 20 * 1024 * 1024)
        guard let team = try await Team.find(id, on: req.db) else { throw Abort(.notFound, reason: "Team not found.") }
        let current = side == .home ? team.trikot.home : team.trikot.away
        guard current == input.expectedImageUrl else {
            throw Abort(.conflict, reason: "This jersey was changed by another administrator. Reload the team before saving.")
        }
        let extensionName = input.image.contentType == .png ? "png" : "jpg"
        let destination = "teams/\(id.uuidString)/jerseys/\(side.rawValue)/\(UUID().uuidString).\(extensionName)"
        let url: String
        do {
            let firebase = req.application.firebaseManager
            try await firebase.authenticate().get()
            url = try await firebase.uploadFile(file: input.image, to: destination).get()
        } catch {
            throw Abort(.badGateway, reason: "The jersey image could not be saved. The current jersey has not been replaced.")
        }
        // Atomic Mongo nested-field update: preserves the other jersey and unrelated team edits.
        // The URL condition also protects against a change made while the upload was running.
        let field = FieldKey.string("trikot.\(side.rawValue)")
        try await Team.query(on: req.db).filter(\.$id == id)
            .filter(.path([field], schema: Team.schema), .equal, .bind(input.expectedImageUrl))
            .set([field: .bind(url)]).update()
        guard let saved = try await Team.find(id, on: req.db),
              (side == .home ? saved.trikot.home : saved.trikot.away) == url else {
            throw Abort(.conflict, reason: "The jersey changed while saving. Reload the team before trying again.")
        }
        return .init(side: side.rawValue, imageUrl: url)
    }
}
