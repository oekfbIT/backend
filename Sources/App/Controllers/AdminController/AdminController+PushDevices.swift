import Fluent
import Foundation
import Vapor

extension AdminController {
    struct RegisteredPushDeviceResponse: Content {
        let id: UUID
        let expoPushToken: String
        let guestId: String
        let playerId: UUID?
        let playerName: String?
        let teamId: UUID?
        let teamName: String?
        let savedDeviceId: UUID?
        let savedLabel: String?
        let platform: DevicePlatform
        let appVersion: String?
        let locale: String?
        let isActive: Bool
        let createdAt: Date?
        let updatedAt: Date?
    }

    func setupPushDeviceRoutes(on root: RoutesBuilder) {
        root.get("push-devices", use: registeredPushDevices)
    }

    func registeredPushDevices(req: Request) async throws -> [RegisteredPushDeviceResponse] {
        let devices = try await DeviceToken.query(on: req.db)
            .sort(\.$updatedAt, .descending)
            .all()
        let savedDevices = try await SavedPushDevice.query(on: req.db).all()
        let savedByToken = Dictionary(uniqueKeysWithValues: savedDevices.map { ($0.expoPushToken, $0) })
        let playerIds = Array(Set(devices.compactMap(\.playerId)))
        let teamIds = Array(Set(devices.compactMap(\.teamId)))
        let players = playerIds.isEmpty
            ? []
            : try await Player.query(on: req.db).filter(\.$id ~~ playerIds).all()
        let teams = teamIds.isEmpty
            ? []
            : try await Team.query(on: req.db).filter(\.$id ~~ teamIds).all()
        let playersById = Dictionary(uniqueKeysWithValues: try players.map { (try $0.requireID(), $0) })
        let teamsById = Dictionary(uniqueKeysWithValues: try teams.map { (try $0.requireID(), $0) })

        var response: [RegisteredPushDeviceResponse] = []
        response.reserveCapacity(devices.count)
        for device in devices {
            let player = device.playerId.flatMap { playersById[$0] }
            let team = device.teamId.flatMap { teamsById[$0] }
            let saved = savedByToken[device.fcmToken]

            response.append(.init(
                id: try device.requireID(),
                expoPushToken: device.fcmToken,
                guestId: device.guestId,
                playerId: device.playerId,
                playerName: player?.name,
                teamId: device.teamId,
                teamName: team?.teamName,
                savedDeviceId: saved?.id,
                savedLabel: saved?.label,
                platform: device.platform,
                appVersion: device.appVersion,
                locale: device.locale,
                isActive: device.isActive,
                createdAt: device.createdAt,
                updatedAt: device.updatedAt
            ))
        }
        return response
    }
}
