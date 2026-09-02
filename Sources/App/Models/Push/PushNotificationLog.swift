import Fluent
import Vapor

final class PushNotificationLog: Model, Content {
    static let schema = "push_notification_logs"

    @ID(key: .id) var id: UUID?
    @Field(key: "title") var title: String
    @Field(key: "body") var body: String
    @Field(key: "target_type") var targetType: String
    @OptionalField(key: "target_label") var targetLabel: String?
    @OptionalField(key: "news_id") var newsId: UUID?
    @OptionalField(key: "path") var path: String?
    @Field(key: "status") var status: String
    @Field(key: "recipient_count") var recipientCount: Int
    @OptionalField(key: "error_message") var errorMessage: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        title: String,
        body: String,
        targetType: String,
        targetLabel: String? = nil,
        newsId: UUID? = nil,
        path: String? = nil,
        status: String,
        recipientCount: Int,
        errorMessage: String? = nil
    ) {
        self.title = title
        self.body = body
        self.targetType = targetType
        self.targetLabel = targetLabel
        self.newsId = newsId
        self.path = path
        self.status = status
        self.recipientCount = recipientCount
        self.errorMessage = errorMessage
    }
}

extension CreatePushNotificationLog: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(PushNotificationLog.schema)
            .id()
            .field("title", .string, .required)
            .field("body", .string, .required)
            .field("target_type", .string, .required)
            .field("target_label", .string)
            .field("news_id", .uuid)
            .field("path", .string)
            .field("status", .string, .required)
            .field("recipient_count", .int, .required)
            .field("error_message", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(PushNotificationLog.schema).delete()
    }
}

final class SavedPushDevice: Model, Content {
    static let schema = "saved_push_devices"

    @ID(key: .id) var id: UUID?
    @Field(key: "label") var label: String
    @Field(key: "expo_push_token") var expoPushToken: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(label: String, expoPushToken: String) {
        self.label = label
        self.expoPushToken = expoPushToken
    }
}

extension CreateSavedPushDevice: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(SavedPushDevice.schema)
            .id()
            .field("label", .string, .required)
            .field("expo_push_token", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "expo_push_token")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(SavedPushDevice.schema).delete()
    }
}
