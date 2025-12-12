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

        // CRUD + index
        conversation.post(use: createConversationApp)
        conversation.get(use: indexConversationsApp)
        conversation.get(":id", use: getConversationByIDApp)
        conversation.delete(":id", use: deleteConversationApp)
        conversation.patch(":id", use: updateConversationApp)

        // team-specific
        conversation.get("team", ":teamId", use: getConversationsForTeamApp)

        // all with team info (if needed)
        conversation.get("teams", use: getAllConversationsWithTeamApp)

        // ✅ ONE universal message route (JSON OR multipart)
        conversation.post(":id", "message", use: sendMessageUniversalApp)

        conversation.post("message", ":messageId", "read", use: markMessageAsReadApp)
        conversation.get("status", ":conversationID", use: toggleStatusApp)
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
    /// All conversations including team info (no filter).
    func getAllConversationsWithTeamApp(req: Request) throws -> EventLoopFuture<[ConversationWrapper]> {
        return Conversation.query(on: req.db)
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

    // MARK: - Messages

    /// POST /app/conversation/:id/message
    /// Universal send: accepts JSON OR multipart/form-data.
    /// Always stores attachments as [] when no file.
    func sendMessageUniversalApp(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let conversationID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let payload = try req.content.decode(SendMessagePayload.self)

        let trimmedText = (payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFile = payload.file?.data.readableBytes ?? 0 > 0

        // must send either text or a file
        guard !trimmedText.isEmpty || hasFile else {
            throw Abort(.badRequest, reason: "Message must include text or an attachment.")
        }

        // ✅ always non-nil attachments array
        var message = Message(
            id: UUID(),
            senderTeam: payload.senderTeam,
            senderName: payload.senderName,
            text: trimmedText,           // can be empty if file-only
            read: false,
            attachments: [],             // ✅ always []
            created: Date.viennaNow
        )

        // If no file: append and save
        if !hasFile {
            return Conversation.find(conversationID, on: req.db)
                .unwrap(or: Abort(.notFound))
                .flatMap { conversation in
                    conversation.messages.append(message)
                    return conversation.save(on: req.db).transform(to: .ok)
                }
        }

        // File exists: upload then append attachment
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

                return Conversation.find(conversationID, on: req.db)
                    .unwrap(or: Abort(.notFound))
                    .flatMap { conversation in
                        conversation.messages.append(message)
                        return conversation.save(on: req.db).transform(to: .ok)
                    }
            }
    }

    /// POST /app/conversation/message/:messageId/read
    /// Mark a single message as read.
    func markMessageAsReadApp(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let messageID = req.parameters.get("messageId", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        return Conversation.query(on: req.db)
            .all()
            .flatMap { conversations in
                if let conversationIndex = conversations.firstIndex(where: { $0.messages.contains(where: { $0.id == messageID }) }) {
                    var conversation = conversations[conversationIndex]
                    if let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageID }) {
                        conversation.messages[messageIndex].read = true
                        return conversation.save(on: req.db).transform(to: .ok)
                    }
                }
                return req.eventLoop.makeFailedFuture(Abort(.notFound))
            }
    }

    // MARK: - CRUD + status (APP)

    /// POST /app/conversation
    func createConversationApp(req: Request) throws -> EventLoopFuture<ConversationWrapper> {
        let conversation = try req.content.decode(Conversation.self)
        conversation.open = true

        return conversation.create(on: req.db).flatMap {
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
    func indexConversationsApp(req: Request) throws -> EventLoopFuture<[ConversationWrapper]> {
        return Conversation.query(on: req.db)
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
