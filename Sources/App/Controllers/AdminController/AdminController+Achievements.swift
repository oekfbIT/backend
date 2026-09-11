import Vapor
import Fluent

extension AdminController {
    func setupAchievementRoutes(on root: RoutesBuilder) {
        let route = root.grouped("achievements", ":ownerType", ":ownerId")
        route.get(use: AchievementSupport.list)
        route.post(use: createAchievement)
        route.put(":achievementId", use: updateAchievement)
        route.delete(":achievementId", use: deleteAchievement)
    }
    func createAchievement(req: Request) async throws -> Achievement {
        let (type, id) = try await AchievementSupport.owner(req)
        let (label, image) = try req.content.decode(AchievementInput.self).normalized()
        let item = Achievement(label: label, imageUrl: image, ownerType: type, ownerId: id)
        try await item.create(on: req.db)
        return item
    }
    func updateAchievement(req: Request) async throws -> Achievement {
        let item = try await AchievementSupport.item(req)
        let (label, image) = try req.content.decode(AchievementInput.self).normalized()
        item.label = label
        item.imageUrl = image
        try await item.update(on: req.db)
        return item
    }
    func deleteAchievement(req: Request) async throws -> HTTPStatus {
        let item = try await AchievementSupport.item(req)
        try await item.delete(on: req.db)
        return .noContent
    }
}
