//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 18.12.25.
//

import Foundation
import Vapor
import Fluent

// MARK: - Stadium Endpoints
extension AppController {
    
    func setupStadiumRoutes(on root: RoutesBuilder) {
        let stadium = root.grouped("stadium")

        stadium.get("all", use: getAllStadiums)
        stadium.get(":id", use: getStadiumByID)
        stadium.get("bundesland", ":bundesland", use: getStadiumsByBundesland)
    }

    func getAllStadiums(req: Request) async throws -> [Stadium] {
        try await Stadium.query(on: req.db)
            .sort(\.$name, .ascending)
            .all()
    }

    // GET /app/stadium/:stadiumID
    func getStadiumByID(req: Request) async throws -> AppStadiumWithForecast {
        // 1️⃣ Extract the stadium ID as a String (MongoDB uses string-based _id)
        guard let stadiumID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid stadium ID.")
        }

        // 2️⃣ Find stadium by ID
        guard let stadium = try await Stadium.find(stadiumID, on: req.db) else {
            throw Abort(.notFound, reason: "Stadium not found.")
        }

        // 3️⃣ Fetch live weather forecast
        let forecast = try await stadium.getWeatherForecast(on: req)

        // 4️⃣ Combine both in a single response
        return AppStadiumWithForecast(stadium: stadium, forecast: forecast)
    }

    // 3️⃣ GET /app/stadiums/bundesland/:bundesland
    func getStadiumsByBundesland(req: Request) async throws -> [Stadium] {
        guard let bundeslandRaw = req.parameters.get("bundesland", as: String.self),
              let bundesland = Bundesland(rawValue: bundeslandRaw) else {
            throw Abort(.badRequest, reason: "Invalid or missing Bundesland.")
        }

        return try await Stadium.query(on: req.db)
            .filter(\.$bundesland == bundesland)
            .sort(\.$name, .ascending)
            .all()
    }
}


