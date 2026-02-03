//
//  AppController+Voting.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 03.02.26.
//

import Foundation
import Vapor
import Fluent

// MARK: - Voting Endpoints
extension AppController {

    // Routes are assumed to be mounted under /app by your main AppController router.
    // This creates:
    // POST   /app/vote/cast
    // POST   /app/vote/uncast
    // GET    /app/vote/match/:matchid/counts
    // GET    /app/vote/match/:matchid/all
    // GET    /app/vote/match/:matchid/hasVoted/:deviceid
    func setupVotingRoutes(on root: RoutesBuilder) {
        let vote = root.grouped("vote")

        vote.post("cast", use: castVote)
        vote.post("uncast", use: uncastVote)

        vote.get("match", ":matchid", "counts", use: getVoteCountsForMatch)
        vote.get("match", ":matchid", "all", use: getAllVotesForMatch)

        vote.get("match", ":matchid", "hasVoted", ":deviceid", use: hasDeviceVotedOnMatch)
    }

    // MARK: - DTOs

    struct CastVoteRequest: Content {
        let deviceid: String
        let matchid: UUID
        let vote: VoteResult
    }

    struct UncastVoteRequest: Content {
        let deviceid: String
        let matchid: UUID
    }

    struct VoteCountsResponse: Content {
        let matchid: UUID
        let home: Int
        let draw: Int
        let away: Int
        let total: Int
    }

    struct HasVotedResponse: Content {
        let matchid: UUID
        let deviceid: String
        let hasVoted: Bool
        let vote: VoteResult?
        let voteId: UUID?
    }

    // MARK: - Handlers

    /// 1️⃣ POST /app/vote/cast
    /// Body: { "deviceid": "...", "matchid": "...", "vote": "home" | "draw" | "away" }
    ///
    /// Behavior:
    /// - If the device already voted on this match, we update the existing row to the new vote.
    /// - Otherwise, we create a new VoteItem.
    @Sendable
    func castVote(req: Request) async throws -> VoteItem {
        let payload = try req.content.decode(CastVoteRequest.self)

        if let existing = try await VoteItem.query(on: req.db)
            .filter(\.$deviceid == payload.deviceid)
            .filter(\.$matchid == payload.matchid)
            .first()
        {
            existing.vote = payload.vote
            try await existing.update(on: req.db)
            return existing
        } else {
            let item = VoteItem(deviceid: payload.deviceid, matchid: payload.matchid, vote: payload.vote)
            try await item.create(on: req.db)
            return item
        }
    }

    /// 2️⃣ POST /app/vote/uncast
    /// Body: { "deviceid": "...", "matchid": "..." }
    ///
    /// Behavior:
    /// - Deletes the existing vote for this (deviceid, matchid) if present.
    /// - Returns 204 regardless (idempotent).
    @Sendable
    func uncastVote(req: Request) async throws -> HTTPStatus {
        let payload = try req.content.decode(UncastVoteRequest.self)

        if let existing = try await VoteItem.query(on: req.db)
            .filter(\.$deviceid == payload.deviceid)
            .filter(\.$matchid == payload.matchid)
            .first()
        {
            try await existing.delete(on: req.db)
        }

        return .noContent
    }

    /// 3️⃣ GET /app/vote/match/:matchid/all
    /// Returns all votes for a match (useful for admin/debug).
    @Sendable
    func getAllVotesForMatch(req: Request) async throws -> [VoteItem] {
        guard let matchid = req.parameters.get("matchid", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid matchid.")
        }

        return try await VoteItem.query(on: req.db)
            .filter(\.$matchid == matchid)
            .sort(\.$created, .ascending)
            .all()
    }

    /// 4️⃣ GET /app/vote/match/:matchid/counts
    /// Returns aggregated counts for a match.
    @Sendable
    func getVoteCountsForMatch(req: Request) async throws -> VoteCountsResponse {
        guard let matchid = req.parameters.get("matchid", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid matchid.")
        }

        let votes = try await VoteItem.query(on: req.db)
            .filter(\.$matchid == matchid)
            .all()

        var home = 0
        var draw = 0
        var away = 0

        for v in votes {
            switch v.vote {
            case .home: home += 1
            case .draw: draw += 1
            case .away: away += 1
            }
        }

        return VoteCountsResponse(
            matchid: matchid,
            home: home,
            draw: draw,
            away: away,
            total: votes.count
        )
    }

    /// 5️⃣ GET /app/vote/match/:matchid/hasVoted/:deviceid
    /// Checks whether the given device has already voted on the match.
    @Sendable
    func hasDeviceVotedOnMatch(req: Request) async throws -> HasVotedResponse {
        guard let matchid = req.parameters.get("matchid", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing or invalid matchid.")
        }

        guard let deviceid = req.parameters.get("deviceid"), !deviceid.isEmpty else {
            throw Abort(.badRequest, reason: "Missing deviceid.")
        }

        let existing = try await VoteItem.query(on: req.db)
            .filter(\.$matchid == matchid)
            .filter(\.$deviceid == deviceid)
            .first()

        return HasVotedResponse(
            matchid: matchid,
            deviceid: deviceid,
            hasVoted: existing != nil,
            vote: existing?.vote,
            voteId: existing?.id
        )
    }
}
