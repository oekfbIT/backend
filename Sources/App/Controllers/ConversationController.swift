//
//  File.swift
//  
//
//  Created by Alon Yakoby on 22.06.24.
//

import Foundation
import Vapor
import Fluent

final class ConversationController: RouteCollection {
    let repository: StandardControllerRepository<Conversation>

    init(path: String) {
        self.repository = StandardControllerRepository<Conversation>(path: path)
    }

    func setupRoutes(on app: RoutesBuilder) throws {
        let route = app.grouped(PathComponent(stringLiteral: repository.path))
        
        route.post(use: repository.create)
        route.get(use: repository.index)
        route.get(":id", use: repository.getbyID)
        route.delete(":id", use: repository.deleteID)
        route.patch(":id", use: repository.updateID)
        route.get("teams", use: getAllConversationsWithTeam)
        route.get("team", ":teamId", use: getConversationsForTeam)
        route.post(":id", "message", use: sendMessage)
        route.post("message", ":messageId", "read", use: markMessageAsRead)
    }

    func boot(routes: RoutesBuilder) throws {
        try setupRoutes(on: routes)
    }
    
    // Function to get all conversations for a team
    func getConversationsForTeam(req: Request) throws -> EventLoopFuture<[Conversation]> {
        guard let teamID = req.parameters.get("teamId", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        return Conversation.query(on: req.db)
            .filter(\.$team.$id == teamID)
            .all()
    }

    func getAllConversationsWithTeam(req: Request) throws -> EventLoopFuture<[Conversation]> {
        return Conversation.query(on: req.db)
            .with(\.$team)
            .all()
    }

    // Function to send a message and add it to a conversation
    func sendMessage(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        guard let conversationID = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        var message = try req.content.decode(Message.self)
        message.id = UUID()
        message.read = false
        message.created = Date()
        
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
}
