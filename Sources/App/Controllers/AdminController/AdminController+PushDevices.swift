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
        // Keep the parameter name aligned with every other /admin/teams/:id route.
        // RoutingKit shares this path node and rejects conflicting parameter names.
        root.get("teams", ":id", "push-devices", use: registeredPushDevicesForTeam)
    }

    func registeredPushDevices(req: Request) async throws -> [RegisteredPushDeviceResponse] {
        let devices = try await DeviceToken.query(on: req.db)
            .sort(\.$updatedAt, .descending)
            .all()
        return try await pushDeviceResponses(for: devices, req: req)
    }

    func registeredPushDevicesForTeam(req: Request) async throws -> [RegisteredPushDeviceResponse] {
        guard let teamId = req.parameters.get("id", as: UUID.self),
              try await Team.find(teamId, on: req.db) != nil
        else {
            throw Abort(.notFound, reason: "Team not found.")
        }

        // Build from the enriched responses so legacy player devices whose
        // teamId has not yet been backfilled are still visible via the player's
        // current team relation.
        let devices = try await DeviceToken.query(on: req.db)
            .sort(\.$updatedAt, .descending)
            .all()
        let responses = try await pushDeviceResponses(for: devices, req: req)
        return responses.filter { $0.teamId == teamId }
    }

    private func pushDeviceResponses(
        for devices: [DeviceToken],
        req: Request
    ) async throws -> [RegisteredPushDeviceResponse] {
        let savedDevices = try await SavedPushDevice.query(on: req.db).all()
        let savedByToken = Dictionary(uniqueKeysWithValues: savedDevices.map { ($0.expoPushToken, $0) })
        let playerIds = Array(Set(devices.compactMap(\.playerId)))
        let players = playerIds.isEmpty
            ? []
            : try await Player.query(on: req.db).filter(\.$id ~~ playerIds).all()
        let teamIds = Array(Set(
            devices.compactMap(\.teamId) + players.compactMap { $0.$team.id }
        ))
        let teams = teamIds.isEmpty
            ? []
            : try await Team.query(on: req.db).filter(\.$id ~~ teamIds).all()
        let playersById = Dictionary(uniqueKeysWithValues: try players.map { (try $0.requireID(), $0) })
        let teamsById = Dictionary(uniqueKeysWithValues: try teams.map { (try $0.requireID(), $0) })

        var response: [RegisteredPushDeviceResponse] = []
        response.reserveCapacity(devices.count)
        for device in devices {
            let player = device.playerId.flatMap { playersById[$0] }
            let effectiveTeamId = device.teamId ?? player?.$team.id
            let team = effectiveTeamId.flatMap { teamsById[$0] }
            let saved = savedByToken[device.fcmToken]

            response.append(.init(
                id: try device.requireID(),
                expoPushToken: device.fcmToken,
                guestId: device.guestId,
                playerId: device.playerId,
                playerName: player?.name,
                teamId: effectiveTeamId,
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
