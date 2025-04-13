//
//  File.swift
//  
//
//  Created by Alon Yakoby on 22.06.24.
//

import Foundation
import Vapor
import Fluent


struct TeamInfo: Codable {
    let id: String
    let name: String
    let icon: String
}

struct ConversationWrapper: Codable, Content {
    var id: UUID?
    var team: TeamInfo?
    var messages: [Message]
    var subject: String
    var icon: String?
    var open: Bool
}

final class ConversationController: RouteCollection {
    let repository: StandardControllerRepository<Conversation>

    init(path: String) {
        self.repository = StandardControllerRepository<Conversation>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: createCustom)
        route.get(use: indexCustom)
        route.get(":id", use: getbyIDCustom)
        route.delete(":id", use: deleteIDCustom)
        route.patch(":id", use: updateIDCustom)
        route.get("teams", use: getAllConversationsWithTeam)
        route.get("team", ":teamId", use: getConversationsForTeam)
        route.post(":id", "message", use: sendMessage)
        route.post("message", ":messageId", "read", use: markMessageAsRead)
        route.get("status", ":conversationID", use: toggleStatus)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    // Function to get all conversations for a team
    func getConversationsForTeam(req: Request) throws -> EventLoopFuture<[ConversationWrapper]> {
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
                            TeamInfo(id: $0.id!.uuidString, name: $0.teamName, icon: $0.logo)
                        },
                        messages: conversation.messages,
                        subject: conversation.subject,
                        icon: conversation.icon,
                        open: conversation.open ?? true 
                    )
                }
            }
    }


    func getAllConversationsWithTeam(req: Request) throws -> EventLoopFuture<[ConversationWrapper]> {
        return Conversation.query(on: req.db)
            .with(\.$team)
            .all()
            .map { conversations in
                conversations.map { conversation in
                    ConversationWrapper(
                        id: conversation.id,
                        team: conversation.team.map {
                            TeamInfo(id: $0.id!.uuidString, name: $0.teamName, icon: $0.logo)
                        },
                        messages: conversation.messages,
                        subject: conversation.subject,
                        icon: conversation.icon,
                        open: conversation.open ?? true
                    )
                }
            }
    }

    // Function to send a message and add it to a conversation
    func sendMessage(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let conversationID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        var message = try req.content.decode(Message.self)
        message.id = UUID()
        message.read = false
        message.created = Date.viennaNow
        
        return Conversation.find(conversationID, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { conversation in
                var updatedConversation = conversation
                updatedConversation.messages.append(message)
                
                return updatedConversation.save(on: req.db).transform(to: .ok)
            }
    }

    // Function to mark a message as read
    func markMessageAsRead(req: Request) throws -> EventLoopFuture<HTTPStatus> {
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
    
    // MARK: NEW FUNCS
    
    func createCustom(req: Request) throws -> EventLoopFuture<ConversationWrapper> {
        let conversation = try req.content.decode(Conversation.self)
        conversation.open = true 
        return conversation.create(on: req.db).flatMap {
            // Eager load the team after the conversation is saved
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

    func indexCustom(req: Request) throws -> EventLoopFuture<[ConversationWrapper]> {
        return Conversation.query(on: req.db).with(\.$team).all().map { conversations in
            conversations.map { conversation in
                ConversationWrapper(
                    id: conversation.id,
                    team: conversation.team.map { TeamInfo(id: $0.id!.uuidString, name: $0.teamName, icon: $0.logo) },
                    messages: conversation.messages,
                    subject: conversation.subject,
                    icon: conversation.icon,
                    open: conversation.open ?? true
                )
            }
        }
    }

    func getbyIDCustom(req: Request) throws -> EventLoopFuture<ConversationWrapper> {
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
                    team: conversation.team.map { TeamInfo(id: $0.id!.uuidString, name: $0.teamName, icon: $0.logo) },
                    messages: conversation.messages,
                    subject: conversation.subject,
                    icon: conversation.icon,
                    open: conversation.open ?? true
                )
            }
    }
    
    func toggleStatus(req: Request) throws -> EventLoopFuture<ConversationWrapper> {
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
                    return req.eventLoop.future(error: Abort(.unprocessableEntity, reason: "`open` is nil and cannot be toggled"))
                }
            }
    }

    func deleteIDCustom(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        return Conversation.find(id, on: req.db)
            .unwrap(or: Abort(.notFound))
            .flatMap { $0.delete(on: req.db).transform(to: .noContent) }
    }

    func updateIDCustom(req: Request) throws -> EventLoopFuture<ConversationWrapper> {
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
                                team: updated.team.map { TeamInfo(id: $0.id!.uuidString, name: $0.teamName, icon: $0.logo) },
                                messages: updated.messages,
                                subject: updated.subject,
                                icon: updated.icon,
                                open: conversation.open ?? true
                            )
                        }
                }
            }
    }

}
