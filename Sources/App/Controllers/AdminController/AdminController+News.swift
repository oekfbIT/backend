// MARK: - Admin News Routes (copy style of your AdminController extensions)
// File: AdminController+NewsRoutes.swift

import Foundation
import Vapor
import Fluent

// MARK: - Routes
extension AdminController {

    /// Mount under: /admin/news/...
    func setupNewsRoutes(on root: RoutesBuilder) {
        let news = root.grouped("news")

        // CRUD
        news.get(use: getAllNews)                      // GET  /admin/news
        news.get(":id", use: getNewsByID)             // GET  /admin/news/:id
        news.post(use: createNews)                    // POST /admin/news
        news.patch(":id", use: patchNews)             // PATCH /admin/news/:id
        news.delete(":id", use: deleteNews)           // DELETE /admin/news/:id

        // Filters (copied from old controller)
        news.get("all", use: getAllExceptStrafsenat)  // GET /admin/news/all
        news.get("strafsenat", use: getAllWithStrafsenat) // GET /admin/news/strafsenat

        // Optional batch (if you want parity)
        news.post("batch", use: createNewsBatch)      // POST /admin/news/batch
        news.patch("batch", use: patchNewsBatch)      // PATCH /admin/news/batch
    }
}

// MARK: - DTOs
extension AdminController {

    /// PATCH payload for /admin/news/:id
    /// Supports BOTH:
    /// - JSON patch (imageURL string)
    /// - multipart/form-data patch (image file upload)
    struct PatchNewsRequest: Content {
        /// ✅ multipart upload (field name: "image")
        let image: File?

        /// ✅ optional manual URL override (field name: "imageURL")
        let imageURL: String?

        let text: String?
        let title: String?
        let youtube: String?
        let tag: String?
        let matchID: String?
    }
    
    struct CreateNewsRequest: Content {
        let title: String?
        let text: String?
        let tag: String?
        let youtube: String?
        let image: File?          // ✅ file upload
        // let matchID: String?    // only if you fix the NewsItem model column
    }

}

// MARK: - Handlers
extension AdminController {

    // GET /admin/news
    func getAllNews(req: Request) async throws -> [NewsItem] {
        try await NewsItem.query(on: req.db)
            .sort(\.$created, .descending)
            .all()
    }

    // GET /admin/news/:id
    func getNewsByID(req: Request) async throws -> NewsItem {
        let id = try req.parameters.require("id", as: UUID.self)
        guard let item = try await NewsItem.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "News item not found.")
        }
        return item
    }

    // POST /admin/news (multipart/form-data)
    func createNews(req: Request) async throws -> NewsItem {
        let body = try req.content.decode(CreateNewsRequest.self)

        // Optional upload
        var imageURL: String? = nil
        if let file = body.image, file.data.readableBytes > 0 {
            let firebaseManager = req.application.firebaseManager
            try await firebaseManager.authenticate().get()

            // Use UUID path so multiple posts don’t overwrite each other
            let key = UUID().uuidString
            let path = "news/\(key)/image"

            imageURL = try await firebaseManager.uploadFile(file: file, to: path).get()
        }

        let item = NewsItem(
            id: nil,
            image: imageURL,
            text: body.text,
            title: body.title,
            tag: body.tag,
            youtube: body.youtube
        )

        try await item.save(on: req.db)
        return item
    }

    /// PATCH /admin/news/:id
        /// - JSON: { title?, text?, youtube?, tag?, imageURL? }
        /// - multipart/form-data: title/text/youtube/tag as fields + image as file field ("image")
        func patchNews(req: Request) async throws -> NewsItem {
            let id = try req.parameters.require("id", as: UUID.self)

            guard let existing = try await NewsItem.find(id, on: req.db) else {
                throw Abort(.notFound, reason: "News item not found.")
            }

            let patch = try req.content.decode(PatchNewsRequest.self)

            // Standard JSON fields
            if let v = patch.text { existing.text = v }
            if let v = patch.title { existing.title = v }
            if let v = patch.youtube { existing.youtube = v }
            if let v = patch.tag { existing.tag = v }

            // Optional manual URL override (useful for admin tools)
            if let url = patch.imageURL {
                existing.image = url
            }

            // Optional file upload override (multipart/form-data)
            if let file = patch.image, file.data.readableBytes > 0 {
                let firebaseManager = req.application.firebaseManager
                try await firebaseManager.authenticate().get()

                let key = UUID().uuidString
                let path = "news/\(key)/image"

                let uploadedURL = try await firebaseManager
                    .uploadFile(file: file, to: path)
                    .get()

                existing.image = uploadedURL
            }

            try await existing.save(on: req.db)
            return existing
        }

    // DELETE /admin/news/:id
    func deleteNews(req: Request) async throws -> HTTPStatus {
        let id = try req.parameters.require("id", as: UUID.self)
        guard let existing = try await NewsItem.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "News item not found.")
        }
        try await existing.delete(on: req.db)
        return .ok
    }

    // GET /admin/news/all
    func getAllExceptStrafsenat(req: Request) async throws -> [NewsItem] {
        try await NewsItem.query(on: req.db)
            .filter(\.$tag != "strafsenat")
            .sort(\.$created, .descending)
            .all()
    }

    // GET /admin/news/strafsenat
    func getAllWithStrafsenat(req: Request) async throws -> [NewsItem] {
        try await NewsItem.query(on: req.db)
            .filter(\.$tag == "strafsenat")
            .sort(\.$created, .descending)
            .all()
    }

    // POST /admin/news/batch
    func createNewsBatch(req: Request) async throws -> [NewsItem] {
        let items = try req.content.decode([NewsItem].self)
        for i in items { try await i.save(on: req.db) }
        return items
    }

    // PATCH /admin/news/batch
    func patchNewsBatch(req: Request) async throws -> HTTPStatus {
        let items = try req.content.decode([NewsItem].self)
        for patch in items {
            guard let id = patch.id, let existing = try await NewsItem.find(id, on: req.db) else { continue }
            _ = existing.merge(from: patch)
            try await existing.save(on: req.db)
        }
        return .ok
    }
}
