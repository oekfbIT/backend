//
//  AppController+Conversation.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 11.12.25.
//

import Foundation
import Vapor
import Fluent

// Reuses existing TeamInfo + ConversationWrapper from ConversationController:
//  struct TeamInfo: Codable { ... }
//  struct ConversationWrapper: Codable, Content { ... }

/// Universal payload that supports:
/// - JSON (text-only): file is nil
/// - multipart/form-data (text + optional file)
///
/// Expected keys from frontend FormData:
/// - senderTeam: "true"/"false"
/// - senderName: optional
/// - text: optional (can be empty if sending only file)
/// - file: optional (RNFile)
/// - name: optional (original filename)
/// - type: optional (mime)
struct SendMessagePayload: Content {
    var senderTeam: Bool
    var senderName: String?
    var text: String?

    var file: File?
    var name: String?
    var type: String?
}

extension AppController {

    // MARK: - Team-scoped queries (APP)
    func setupChatRoutes(on route: RoutesBuilder) throws {
        // base: /app/conversation
        let conversation = route.grouped("conversation")
        let admin = conversation.grouped(AdminOnlyMiddleware())

        // CRUD + index
        conversation.post(use: createConversationApp)
        conversation.get(use: indexConversationsApp)
        conversation.grouped(":id")
            .grouped(ConversationParameterAccessMiddleware(parameter: "id"))
            .get(use: getConversationByIDApp)
        admin.delete(":id", use: deleteConversationApp)
        admin.patch(":id", use: updateConversationApp)

        // team-specific
        conversation.grouped("team", ":teamId")
            .grouped(TeamParameterAccessMiddleware(parameter: "teamId"))
            .get(use: getConversationsForTeamApp)

        // all with team info (if needed)
        conversation.get("teams", use: getAllConversationsWithTeamApp)

        // ✅ ONE universal message route (JSON OR multipart)
        conversation.grouped(":id")
            .grouped(ConversationParameterAccessMiddleware(parameter: "id"))
            .on(.POST, "message", body: .collect(maxSize: "10mb"), use: sendMessageUniversalApp)

        conversation.post("message", ":messageId", "read", use: markMessageAsReadApp)
        conversation.grouped("status", ":conversationID")
            .grouped(ConversationParameterAccessMiddleware(parameter: "conversationID"))
            .get(use: toggleStatusApp)
    }

    /// GET /app/conversation/team/:teamId
    /// All conversations for a given team.
    func getConversationsForTeamApp(req: Request) throws -> EventLoopFuture<[ConversationWrapper]> {
        guard let teamID = req.parameters.get("teamId", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        return Conversation.query(on: req.db)
            .filter(\.$team.$id == teamID)
            .with(\.$team)
            .all()
            .map { conversations in
                conversations.map { conversation in
                    ConversationWrapper(
                        id: conversation.id,
                        team: conversation.team.map {
                            TeamInfo(
                                id: $0.id!.uuidString,
                                name: $0.teamName,
                                icon: $0.logo
                            )
                        },
                        messages: conversation.messages,
                        subject: conversation.subject,
                        icon: conversation.icon,
                        open: conversation.open ?? true
                    )
                }
            }
    }

    /// GET /app/conversation/teams
    /// Accessible conversations including team info.
    func getAllConversationsWithTeamApp(req: Request) async throws -> [ConversationWrapper] {
        try await accessibleConversationWrappers(req: req)
    }

    // MARK: - Messages

    /// POST /app/conversation/:id/message
    /// Universal send: accepts JSON OR multipart/form-data.
    /// Always stores attachments as [] when no file.
    /// ✅ If senderTeam == false (admin -> team): sends push to all active devices for that team.
    func sendMessageUniversalApp(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let conversationID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let payload = try req.content.decode(SendMessagePayload.self)
        let user = try req.auth.require(User.self)
        guard user.type == .admin || payload.senderTeam else {
            throw Abort(.forbidden, reason: "Only an administrator can send an administrator message.")
        }

        let trimmedText = (payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFile = (payload.file?.data.readableBytes ?? 0) > 0
        if let file = payload.file, hasFile {
            try UploadValidation.validate(file, allowed: [.jpeg, .png, .pdf])
        }

        // must send either text or a file
        guard !trimmedText.isEmpty || hasFile else {
            throw Abort(.badRequest, reason: "Message must include text or an attachment.")
        }

        // ✅ always non-nil attachments array
        var message = Message(
            id: UUID(),
            senderTeam: payload.senderTeam,
            senderName: payload.senderName,
            text: trimmedText,   // can be empty if file-only
            read: false,
            attachments: [],     // ✅ always []
            created: Date.viennaNow
        )

        // ✅ Push helper: admin -> team devices only
        func pushIfNeeded(teamId: UUID?, bodyText: String) -> EventLoopFuture<Void> {
            guard payload.senderTeam == false else {
                return req.eventLoop.makeSucceededFuture(())
            }
            guard let teamId else {
                return req.eventLoop.makeSucceededFuture(())
            }

            return req.eventLoop.makeFutureWithTask {
                let tokens = try await DeviceToken.query(on: req.db)
                    .filter(\.$teamId == teamId)
                    .filter(\.$isActive == true)
                    .all()
                    .map(\.fcmToken)

                if tokens.isEmpty { return }

                let finalBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Sie haben eine neue Nachricht."
                    : bodyText

                // Uses ExpoPushService from AppController+Push.swift
                try await ExpoPushService.send(
                    to: tokens,
                    title: "Neue Nachricht",
                    body: finalBody,
                    data: [
                        "type": PushType.conversationMessage.rawValue,
                        "conversationId": conversationID.uuidString,
                        "teamId": teamId.uuidString,
                    ],
                    req: req
                )
            }
        }

        // 1) If no file: save and push
        if !hasFile {
            return Conversation.query(on: req.db)
                .filter(\.$id == conversationID)
                .first()
                .unwrap(or: Abort(.notFound))
                .flatMap { conversation in
                    let teamId = conversation.$team.id

                    conversation.messages.append(message)
                    return conversation.save(on: req.db)
                        .flatMap {
                            pushIfNeeded(teamId: teamId, bodyText: trimmedText)
                                .transform(to: .ok)
                        }
                }
        }

        // 2) If file exists: upload to Firebase first, then save and push
        let file = payload.file!
        let firebaseManager = req.application.firebaseManager

        let attachmentID = UUID().uuidString.lowercased()
        let basePath = "conversation_attachments/\(conversationID.uuidString)"
        let filePath = "\(basePath)/\(attachmentID)"

        return firebaseManager.authenticate()
            .flatMap {
                firebaseManager.uploadFile(file: file, to: filePath)
            }
            .flatMap { downloadURL in
                let attachment = Attachment(
                    name: payload.name ?? file.filename,
                    url: downloadURL,
                    type: payload.type ?? file.contentType?.description
                )

                message.attachments = [attachment]

                return Conversation.query(on: req.db)
                    .filter(\.$id == conversationID)
                    .first()
                    .unwrap(or: Abort(.notFound))
                    .flatMap { conversation in
                        let teamId = conversation.$team.id

                        conversation.messages.append(message)
                        return conversation.save(on: req.db)
                            .flatMap {
                                let pushBody = trimmedText.isEmpty
                                    ? "📎 Anhang erhalten"
                                    : "📎 \(trimmedText)"

                                return pushIfNeeded(teamId: teamId, bodyText: pushBody)
                                    .transform(to: .ok)
                            }
                    }
            }
    }

    /// POST /app/conversation/message/:messageId/read
    /// Mark a single message as read.
    func markMessageAsReadApp(req: Request) async throws -> HTTPStatus {
        guard let messageID = req.parameters.get("messageId", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let conversations = try await Conversation.query(on: req.db)
            .all()
        guard let conversation = conversations.first(where: {
            $0.messages.contains(where: { $0.id == messageID })
        }), let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageID }) else {
            throw Abort(.notFound)
        }
        guard let teamID = conversation.$team.id else {
            throw Abort(.forbidden, reason: "Conversation has no owning team.")
        }
        _ = try await ApplicationAccess.requireTeam(teamID, req: req)

        conversation.messages[messageIndex].read = true
        try await conversation.save(on: req.db)
        return .ok
    }

    // MARK: - CRUD + status (APP)

    // Add near AppController+Conversation.swift

    struct CreateConversationAppRequest: Content {
        var teamId: UUID
        var subject: String
    }
    /// POST /app/conversation
    func createConversationApp(req: Request) throws -> EventLoopFuture<ConversationWrapper> {
        let payload = try req.content.decode(CreateConversationAppRequest.self)

        let conversation = Conversation(
            id: nil,
            teamId: payload.teamId,
            subject: payload.subject,
            open: true
        )

        // ✅ IMPORTANT: messages must be initialized (your DB stores JSON array)
        conversation.messages = []

        return req.eventLoop.makeFutureWithTask {
            _ = try await ApplicationAccess.requireTeam(payload.teamId, req: req)
        }.flatMap {
            conversation.create(on: req.db)
        }.flatMap {
            conversation.$team.load(on: req.db).map {
                let teamInfo: TeamInfo? = {
                    if let team = conversation.team,
                       let teamId = conversation.$team.id {
                        return TeamInfo(
                            id: teamId.uuidString,
                            name: team.teamName,
                            icon: team.logo
                        )
                    }
                    return nil
                }()

                return ConversationWrapper(
                    id: conversation.id,
                    team: teamInfo,
                    messages: conversation.messages,
                    subject: conversation.subject,
                    icon: conversation.icon,
                    open: true
                )
            }
        }
    }
    
    /// GET /app/conversation
    func indexConversationsApp(req: Request) async throws -> [ConversationWrapper] {
        try await accessibleConversationWrappers(req: req)
    }

    /// Returns all conversations for administrators and only conversations
    /// belonging to the authenticated user's teams for every other account.
    private func accessibleConversationWrappers(req: Request) async throws -> [ConversationWrapper] {
        let user = try req.auth.require(User.self)
        let query = Conversation.query(on: req.db).with(\.$team)

        let conversations: [Conversation]
        if user.type == .admin {
            conversations = try await query.all()
        } else {
            guard let userID = user.id else {
                throw Abort(.unauthorized, reason: "Authenticated user has no identifier.")
            }

            let teamIDs = try await Team.query(on: req.db)
                .filter(\.$user.$id == userID)
                .all()
                .compactMap(\.id)

            guard !teamIDs.isEmpty else { return [] }
            conversations = try await query
                .filter(\.$team.$id ~~ teamIDs)
                .all()
        }

        return conversations.map { conversation in
            ConversationWrapper(
                id: conversation.id,
                team: conversation.team.map {
                    TeamInfo(
                        id: $0.id!.uuidString,
                        name: $0.teamName,
                        icon: $0.logo
                    )
                },
                messages: conversation.messages,
                subject: conversation.subject,
                icon: conversation.icon,
                open: conversation.open ?? true
            )
        }
    }

    /// GET /app/conversation/:id
    func getConversationByIDApp(req: Request) throws -> EventLoopFuture<ConversationWrapper> {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        return Conversation.query(on: req.db)
            .with(\.$team)
            .filter(\.$id == id)
            .first()
            .unwrap(or: Abort(.notFound))
            .map { conversation in
                ConversationWrapper(
                    id: conversation.id,
                    team: conversation.team.map {
                        TeamInfo(
                            id: $0.id!.uuidString,
                            name: $0.teamName,
                            icon: $0.logo
                        )
                    },
                    messages: conversation.messages,
                    subject: conversation.subject,
                    icon: conversation.icon,
                    open: conversation.open ?? true
                )
            }
    }

    /// GET /app/conversation/status/:conversationID
    func toggleStatusApp(req: Request) throws -> EventLoopFuture<ConversationWrapper> {
        guard let id = req.parameters.get("conversationID", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        return Conversation.query(on: req.db)
            .with(\.$team)
            .filter(\.$id == id)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { conversation in
                if let currentOpen = conversation.open {
                    let toggled = !currentOpen
                    conversation.open = toggled
                    return conversation.save(on: req.db).map {
                        ConversationWrapper(
                            id: conversation.id,
                            team: conversation.team.map {
                                TeamInfo(
                                    id: $0.id!.uuidString,
                                    name: $0.teamName,
                                    icon: $0.logo
                                )
                            },
                            messages: conversation.messages,
                            subject: conversation.subject,
                            icon: conversation.icon,
                            open: toggled
                        )
                    }
                } else {
                    return req.eventLoop.future(
                        error: Abort(
                            .unprocessableEntity,
                            reason: "`open` is nil and cannot be toggled"
                        )
                    )
                }
            }
    }

    /// DELETE /app/conversation/:id
    func deleteConversationApp(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        return Conversation.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { $0.delete(on: req.db).transform(to: .noContent) }
    }

    /// PATCH /app/conversation/:id
    func updateConversationApp(req: Request) throws -> EventLoopFuture<ConversationWrapper> {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let updatedConversation = try req.content.decode(Conversation.self)

        return Conversation.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { conversation in
                let merged = conversation.merge(from: updatedConversation)
                return merged.update(on: req.db).flatMap {
                    Conversation.query(on: req.db)
                        .with(\.$team)
                        .filter(\.$id == id)
                        .first()
                        .unwrap(or: Abort(.notFound))
                        .map { updated in
                            ConversationWrapper(
                                id: updated.id,
                                team: updated.team.map {
                                    TeamInfo(
                                        id: $0.id!.uuidString,
                                        name: $0.teamName,
                                        icon: $0.logo
                                    )
                                },
                                messages: updated.messages,
                                subject: updated.subject,
                                icon: updated.icon,
                                open: updated.open ?? true
                            )
                        }
                }
            }
    }
}
