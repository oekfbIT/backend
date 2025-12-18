//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 18.12.25.
//

import Foundation
import Vapor
import Fluent


// MARK: - News Endpoints
extension AppController {
    func setupNewsRoutes(on root: RoutesBuilder) {
        let news = root.grouped("news")

        news.get("all", use: getAllNews)
        news.get("strafsenat", use: getStrafsenatNews)
        news.get(":id", use: getNewsByID)
    }

    // 1️⃣ GET /app/news/all
    func getAllNews(req: Request) async throws -> [NewsItem] {
        try await NewsItem.query(on: req.db)
            .filter(\.$tag == "Alle")
            .sort(\.$created, .descending)
            .all()
    }

    // 2️⃣ GET /app/news/strafsenat
    func getStrafsenatNews(req: Request) async throws -> [NewsItem] {
        try await NewsItem.query(on: req.db)
            .filter(\.$tag == "strafsenat ")
            .sort(\.$created, .descending)
            .all()
    }

    // 3️⃣ GET /app/news/:id
    func getNewsByID(req: Request) async throws -> NewsItem {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid news ID.")
        }

        guard let news = try await NewsItem.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "News item not found.")
        }

        return news
    }
}
