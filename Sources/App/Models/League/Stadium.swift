//
//  File.swift
//  
//
//  Created by Alon Yakoby on 24.04.24.
//

import Foundation
import Fluent
import Vapor

final class Stadium: Model, Content, Codable {
    static let schema = "stadiums"

    @ID(custom: FieldKeys.id) var id: UUID?
    @Field(key: FieldKeys.bundesland) var bundesland: Bundesland
    @Field(key: FieldKeys.code) var code: String
    @Field(key: FieldKeys.name) var name: String
    @Field(key: FieldKeys.address) var address: String
    @OptionalField(key: FieldKeys.image) var image: String?
    @Field(key: FieldKeys.type) var type: String
    @Field(key: FieldKeys.schuhwerk) var schuhwerk: String
    @Field(key: FieldKeys.flutlicht) var flutlicht: Bool
    @Field(key: FieldKeys.parking) var parking: Bool
    @Field(key: FieldKeys.homeTeam) var homeTeam: String?
    @Field(key: FieldKeys.partnerSince) var partnerSince: String?
    @OptionalField(key: FieldKeys.lat) var lat: Double?
    @OptionalField(key: FieldKeys.lon) var lon: Double?

    enum FieldKeys {
        static var id: FieldKey { "id" }
        static let code: FieldKey = "code"
        static let lat: FieldKey = "lat"
        static let lon: FieldKey = "lon"
        static let name: FieldKey = "name"
        static let bundesland: FieldKey = "bundesland"
        static let address: FieldKey = "address"
        static let type: FieldKey = "type"
        static let image: FieldKey = "image"
        static let schuhwerk: FieldKey = "schuhwerk"
        static let flutlicht: FieldKey = "flutlicht"
        static let parking: FieldKey = "parking"
        static let homeTeam: FieldKey = "homeTeam"
        static let partnerSince: FieldKey = "partnerSince"
    }

    init() {}

    init(id: UUID? = nil, bundesland: Bundesland, code: String, name: String, address: String, image: String? = nil, type: String, schuhwerk: String, flutlicht: Bool, parking: Bool, homeTeam: String?, partnerSince: String?, lat: Double? = nil, lon: Double? = nil) {
        self.id = id
        self.bundesland = bundesland
        self.code = code
        self.name = name
        self.address = address
        self.lat = lat
        self.lon = lon
        self.image = image
        self.type = type
        self.schuhwerk = schuhwerk
        self.flutlicht = flutlicht
        self.parking = parking
        self.homeTeam = homeTeam
        self.partnerSince = partnerSince
    }
}

// Stadium Migration
extension StadiumMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Stadium.schema)
            .field(Stadium.FieldKeys.id, .uuid, .identifier(auto: true))
            .field(Stadium.FieldKeys.bundesland, .string, .required)
            .field(Stadium.FieldKeys.code, .string, .required)
            .field(Stadium.FieldKeys.name, .string, .required)
            .field(Stadium.FieldKeys.address, .string, .required)
            .field(Stadium.FieldKeys.image, .string)
            .field(Stadium.FieldKeys.type, .string)
            .field(Stadium.FieldKeys.schuhwerk, .string)
            .field(Stadium.FieldKeys.flutlicht, .bool)
            .field(Stadium.FieldKeys.parking, .bool)
            .field(Stadium.FieldKeys.homeTeam, .string)
            .field(Stadium.FieldKeys.partnerSince, .string)
            .field(Stadium.FieldKeys.lat, .double)
            .field(Stadium.FieldKeys.lon, .double)
            .create()
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Stadium.schema).delete()
    }
}


extension Stadium: Mergeable {
    func merge(from other: Stadium) -> Stadium {
        var merged = self
        merged.id = other.id
        merged.bundesland = other.bundesland
        merged.code = other.code
        merged.name = other.name
        merged.address = other.address
        merged.image = other.image
        merged.type = other.type
        merged.schuhwerk = other.schuhwerk
        merged.flutlicht = other.flutlicht
        merged.parking = other.parking
        merged.homeTeam = other.homeTeam
        merged.partnerSince = other.partnerSince
        merged.lat = other.lat
        merged.lon = other.lon
        return merged
    }
}

extension Stadium {

    struct WeatherResponse: Codable, Content {
        let stadiumName: String
        let address: String
        let bundesland: String
        let temperature: Double
        let windSpeed: Double
        let precipitation: Double
        let condition: String
        let time: String
    }

    private static var coordinateCache: [String: (Double, Double)] = [:]

    func getWeatherForecast(on req: Request) async throws -> WeatherResponse {
        // 1️⃣ Determine coordinates
        let (latitude, longitude): (Double, Double)
        if let lat = self.lat, let lon = self.lon {
            (latitude, longitude) = (lat, lon)
        } else {
            let query = "\(address), \(bundesland.rawValue), Austria"
            let cacheKey = query.lowercased()

            if let cached = Self.coordinateCache[cacheKey] {
                (latitude, longitude) = cached
            } else {
                // Geocode via Open-Meteo API
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                let geoURL = URI(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=1&language=en&country=AT&format=json")

                let geoResponse = try await req.client.get(geoURL)
                guard geoResponse.status == .ok else {
                    throw Abort(.badRequest, reason: "Geocoding API failed for \(query)")
                }

                struct GeoResult: Codable {
                    struct Result: Codable { let latitude: Double; let longitude: Double }
                    let results: [Result]?
                }

                let geo = try geoResponse.content.decode(GeoResult.self)
                guard let result = geo.results?.first else {
                    throw Abort(.notFound, reason: "Could not find coordinates for \(query)")
                }

                (latitude, longitude) = (result.latitude, result.longitude)
                Self.coordinateCache[cacheKey] = (latitude, longitude)
            }
        }

        // 2️⃣ Fetch hourly weather from Open-Meteo
        let urlString =
        "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&hourly=temperature_2m,precipitation,weathercode,windspeed_10m&timezone=auto"

        let weatherResponse = try await req.client.get(URI(string: urlString))
        guard weatherResponse.status == .ok else {
            let body = weatherResponse.body?.string ?? "No response body"
            throw Abort(.badRequest, reason: "Weather API failed (\(weatherResponse.status)): \(body)")
        }

        // 3️⃣ Decode JSON safely (literal underscore keys)
        struct RawWeather: Codable {
            struct Hourly: Codable {
                let time: [String]
                let temperature_2m: [Double]
                let precipitation: [Double]
                let weathercode: [Int]
                let windspeed_10m: [Double]
            }
            let hourly: Hourly
        }

        let raw: RawWeather
        do {
            let data = weatherResponse.body?.getData(at: 0, length: weatherResponse.body?.readableBytes ?? 0) ?? Data()
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .useDefaultKeys
            raw = try decoder.decode(RawWeather.self, from: data)
        } catch {
            let body = weatherResponse.body?.string ?? "Empty body"
            req.logger.warning("❌ Failed to decode Open-Meteo response for \(name): \(error.localizedDescription)\nBody: \(body)")
            throw Abort(.badRequest, reason: "Unexpected weather API format for \(name)")
        }

        // 4️⃣ Find next forecast hour
        let times = raw.hourly.time
        guard let currentIndex = times.firstIndex(where: {
            if let date = ISO8601DateFormatter().date(from: $0) {
                return date >= Date()
            }
            return false
        }) ?? times.indices.last else {
            throw Abort(.notFound, reason: "No valid forecast data for \(name)")
        }

        // 5️⃣ Map weather code → readable description
        let code = raw.hourly.weathercode[currentIndex]
        let condition: String
        switch code {
        case 0: condition = "Clear"
        case 1...3: condition = "Partly Cloudy"
        case 45, 48: condition = "Fog"
        case 51...67: condition = "Rain"
        case 71...77: condition = "Snow"
        case 80...82: condition = "Showers"
        case 95...99: condition = "Thunderstorm"
        default: condition = "Unknown"
        }

        // ✅ Return structured response
        return WeatherResponse(
            stadiumName: name,
            address: address,
            bundesland: bundesland.rawValue,
            temperature: raw.hourly.temperature_2m[currentIndex],
            windSpeed: raw.hourly.windspeed_10m[currentIndex],
            precipitation: raw.hourly.precipitation[currentIndex],
            condition: condition,
            time: times[currentIndex]
        )
    }
}

private extension ByteBuffer {
    var string: String? { getString(at: 0, length: readableBytes) }
}

