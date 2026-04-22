import Vapor
import Fluent
import Foundation

enum PostponePushNotifier {

    private static let postponePath = "/management/team/postpone-requests"

    static func notifyRequestCreated(
        req: Request,
        postponeRequest: PostponeRequest,
        targetTeamId: UUID
    ) -> EventLoopFuture<Void> {
        sendToTeam(
            req: req,
            teamId: targetTeamId,
            title: "Neuer Spielverlegungsantrag",
            body: "\(postponeRequest.requester.teamName) hat einen Spielverlegungsantrag gesendet.",
            type: .postponeRequestCreated,
            postponeRequest: postponeRequest
        )
    }

    static func notifyRequestApproved(
        req: Request,
        postponeRequest: PostponeRequest,
        targetTeamId: UUID
    ) -> EventLoopFuture<Void> {
        sendToTeam(
            req: req,
            teamId: targetTeamId,
            title: "Spielverlegungsantrag genehmigt",
            body: "\(postponeRequest.requestee.teamName) hat euren Antrag genehmigt.",
            type: .postponeRequestApproved,
            postponeRequest: postponeRequest
        )
    }

    static func notifyRequestDenied(
        req: Request,
        postponeRequest: PostponeRequest,
        targetTeamId: UUID
    ) -> EventLoopFuture<Void> {
        sendToTeam(
            req: req,
            teamId: targetTeamId,
            title: "Spielverlegungsantrag abgelehnt",
            body: "\(postponeRequest.requestee.teamName) hat euren Antrag abgelehnt.",
            type: .postponeRequestDenied,
            postponeRequest: postponeRequest
        )
    }

    private static func sendToTeam(
        req: Request,
        teamId: UUID,
        title: String,
        body: String,
        type: AppController.PushType,
        postponeRequest: PostponeRequest
    ) -> EventLoopFuture<Void> {
        DeviceToken.query(on: req.db)
            .filter(\.$isActive == true)
            .filter(\.$teamId == teamId)
            .all()
            .flatMap { devices in
                let tokens = Array(Set(
                    devices
                        .map(\.fcmToken)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                ))

                guard !tokens.isEmpty else {
                    req.logger.info("[push] No active device tokens for team \(teamId.uuidString)")
                    return req.eventLoop.makeSucceededFuture(())
                }

                let data: [String: String] = [
                    "type": type.rawValue,
                    "path": postponePath,
                    "teamId": teamId.uuidString,
                    "requestId": postponeRequest.id?.uuidString ?? "",
                    "matchId": postponeRequest.$match.id.uuidString,
                    "requesterTeamId": postponeRequest.requester.id?.uuidString ?? "",
                    "requesteeTeamId": postponeRequest.requestee.id?.uuidString ?? ""
                ]

                return req.eventLoop.makeFutureWithTask {
                    do {
                        try await ExpoPushService.send(
                            to: tokens,
                            title: title,
                            body: body,
                            data: data,
                            req: req
                        )
                    } catch {
                        req.logger.warning("[push] Failed to send postpone push: \(error)")
                    }
                }
            }
    }
}
