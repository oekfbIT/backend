import Fluent
import Foundation
import Vapor

extension AppController {
    struct SavePushDeviceRequest: Content {
        let label: String
        let expoPushToken: String
    }

    struct ManagedPushRequest: Content {
        let title: String
        let body: String
        let newsId: UUID?
        let savedDeviceId: UUID?
    }

    struct PushRecipientCountResponse: Content {
        let count: Int
    }

    func setupPushManagerRoutes(on route: RoutesBuilder) {
        let notifications = route.grouped("notifications")
        notifications.get("history", use: pushNotificationHistory)
        notifications.get("recipient-count", use: pushRecipientCount)
        notifications.get("saved-devices", use: savedPushDevices)
        notifications.post("saved-devices", use: savePushDevice)
        notifications.delete("saved-devices", ":id", use: deleteSavedPushDevice)
        notifications.post("test-send", use: managedTestPush)
        notifications.post("broadcast-managed", use: managedBroadcastPush)
    }

    func pushNotificationHistory(req: Request) async throws -> [PushNotificationLog] {
        try await PushNotificationLog.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .limit(100)
            .all()
    }

    func pushRecipientCount(req: Request) async throws -> PushRecipientCountResponse {
        let count = try await DeviceToken.query(on: req.db)
            .filter(\.$isActive == true)
            .count()
        return .init(count: count)
    }

    func savedPushDevices(req: Request) async throws -> [SavedPushDevice] {
        try await SavedPushDevice.query(on: req.db)
            .sort(\.$label, .ascending)
            .all()
    }

    func savePushDevice(req: Request) async throws -> SavedPushDevice {
        let dto = try req.content.decode(SavePushDeviceRequest.self)
        let label = dto.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = dto.expoPushToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !label.isEmpty else { throw Abort(.badRequest, reason: "Device label is required.") }
        guard token.hasPrefix("ExpoPushToken[") || token.hasPrefix("ExponentPushToken[") else {
            throw Abort(.badRequest, reason: "Enter a valid Expo push token.")
        }

        if let existing = try await SavedPushDevice.query(on: req.db)
            .filter(\.$expoPushToken == token)
            .first() {
            existing.label = label
            try await existing.save(on: req.db)
            return existing
        }

        let device = SavedPushDevice(label: label, expoPushToken: token)
        try await device.save(on: req.db)
        return device
    }

    func deleteSavedPushDevice(req: Request) async throws -> HTTPStatus {
        let id = try req.parameters.require("id", as: UUID.self)
        guard let device = try await SavedPushDevice.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Saved device not found.")
        }
        try await device.delete(on: req.db)
        return .noContent
    }

    func managedTestPush(req: Request) async throws -> PushNotificationLog {
        let dto = try validatedManagedPush(req)
        guard let deviceId = dto.savedDeviceId,
              let device = try await SavedPushDevice.find(deviceId, on: req.db) else {
            throw Abort(.badRequest, reason: "Choose a saved test device.")
        }

        return try await sendManagedPush(
            dto,
            tokens: [device.expoPushToken],
            targetType: "singleDevice",
            targetLabel: device.label,
            req: req
        )
    }

    func managedBroadcastPush(req: Request) async throws -> PushNotificationLog {
        let dto = try validatedManagedPush(req)
        let devices = try await DeviceToken.query(on: req.db)
            .filter(\.$isActive == true)
            .all()
        let tokens = Array(Set(devices.map(\.fcmToken)))
        guard !tokens.isEmpty else { throw Abort(.notFound, reason: "No active device tokens found.") }

        return try await sendManagedPush(
            dto,
            tokens: tokens,
            targetType: "broadcast",
            targetLabel: nil,
            req: req
        )
    }

    private func validatedManagedPush(_ req: Request) throws -> ManagedPushRequest {
        let dto = try req.content.decode(ManagedPushRequest.self)
        guard !dto.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Title is required.")
        }
        guard !dto.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Message is required.")
        }
        return dto
    }

    private func sendManagedPush(
        _ dto: ManagedPushRequest,
        tokens: [String],
        targetType: String,
        targetLabel: String?,
        req: Request
    ) async throws -> PushNotificationLog {
        let path = dto.newsId.map { "/news/\($0.uuidString)" }
        var data = ["type": dto.newsId == nil ? "broadcast" : "news.open"]
        if let newsId = dto.newsId?.uuidString {
            data["newsId"] = newsId
            data["path"] = path
        }

        let log = PushNotificationLog(
            title: dto.title,
            body: dto.body,
            targetType: targetType,
            targetLabel: targetLabel,
            newsId: dto.newsId,
            path: path,
            status: "pending",
            recipientCount: tokens.count
        )
        try await log.save(on: req.db)

        do {
            try await ExpoPushService.send(to: tokens, title: dto.title, body: dto.body, data: data, req: req)
            log.status = "submitted"
            try await log.save(on: req.db)
            return log
        } catch {
            log.status = "failed"
            log.errorMessage = String(describing: error)
            try? await log.save(on: req.db)
            throw error
        }
    }
}
