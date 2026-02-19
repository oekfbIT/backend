//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 09.12.25.
//

import Foundation
import Fluent
import Vapor

// MARK: - Registration DTOs

/// For team-initiated registrations (team ID required).
struct RegisterTeamPlayerRequest: Content {
    let teamID: UUID

    let name: String
    let number: String
    let position: String          // expected: "Feldspieler" or "Tormann"
    let email: String
    let nationality: String
    let birthday: String          // birth year or full date string

    /// Files from multipart/form-data
    let playerImage: File
    let identificationImage: File
}

/// For pool registrations (future use, team can be nil).
/// Not used yet – just defined for later.
struct RegisterPoolPlayerRequest: Content {
    let teamID: UUID?

    let name: String
    let number: String
    let position: String
    let email: String
    let nationality: String
    let birthday: String

    let playerImage: File
    let identificationImage: File
}

// MARK: - AppController extension

extension AppController {

    /// POST /app/register/team
    /// Body: multipart/form-data with RegisterTeamPlayerRequest.
    /// Returns: Player.Public
    func registerTeamPlayer(req: Request) throws -> EventLoopFuture<Player.Public> {
        let payload = try req.content.decode(RegisterTeamPlayerRequest.self)

        // --- Basic validation ---

        func nonEmpty(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard nonEmpty(payload.name) else {
            throw Abort(.badRequest, reason: "Player name is required.")
        }
        guard nonEmpty(payload.number) else {
            throw Abort(.badRequest, reason: "Player number is required.")
        }
        guard nonEmpty(payload.email) else {
            throw Abort(.badRequest, reason: "Player email is required.")
        }
        guard nonEmpty(payload.nationality) else {
            throw Abort(.badRequest, reason: "Player nationality is required.")
        }
        guard nonEmpty(payload.birthday) else {
            throw Abort(.badRequest, reason: "Player birthday/birth year is required.")
        }

        // Only allow the two positions you mentioned
        let allowedPositions = ["Feldspieler", "Tormann"]
        guard allowedPositions.contains(payload.position) else {
            throw Abort(.badRequest, reason: "Invalid position. Allowed: Feldspieler, Tormann.")
        }

        // Quick sanity check for files (non-empty)
        guard payload.playerImage.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Player image file is required.")
        }
        guard payload.identificationImage.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Identification image file is required.")
        }

        // --- Firebase upload setup ---

        let firebaseManager = req.application.firebaseManager

        // 6-digit SID (if not generated elsewhere)
        let sid = generateSixDigitSID()

        let basePath = "players/\(sid)"
        let playerImagePath = "\(basePath)/player_image"
        let identificationImagePath = "\(basePath)/player_identification"

        // --- Authenticate and upload both files ---

        return firebaseManager.authenticate().flatMap {
            let imgFuture = firebaseManager.uploadFile(
                file: payload.playerImage,
                to: playerImagePath
            )
            let idFuture = firebaseManager.uploadFile(
                file: payload.identificationImage,
                to: identificationImagePath
            )
            return imgFuture.and(idFuture)
        }
        .flatMap { playerImageURL, identificationURL in
            // --- Build Player with defaults ---

            let eligibility: PlayerEligibility = .Warten
            let bank: Bool = false      // default, not exposed to client
            let status: Bool = true     // assumption: new player is active

            let registerDate = self.currentRegisterDateString()

            let player = Player(
                id: nil,
                sid: sid,
                image: playerImageURL,
                team_oeid: nil,
                email: payload.email,
                balance: nil,
                name: payload.name,
                number: payload.number,
                birthday: payload.birthday,
                teamID: payload.teamID,
                nationality: payload.nationality,
                position: payload.position,
                eligibility: eligibility,
                registerDate: registerDate,
                identification: identificationURL,
                status: status,
                isCaptain: false,
                bank: bank,
                blockdate: nil
            )

            // Save player, then run the same Rechnung logic as `create`
            return player.create(on: req.db).flatMap {
                self.createRegistrationInvoice(for: player, req: req)
            }
            .map { savedPlayer in
                savedPlayer.asPublic()
            }
        }
    }

    // MARK: - Shared invoice logic (factored from create)

    /// Same logic as your existing `create` function (5€ Rechnung per player).
    private func createRegistrationInvoice(
        for player: Player,
        req: Request
    ) -> EventLoopFuture<Player> {
        // Fetch again to ensure relations are loaded (matches your existing pattern)
        return Player.find(player.id, on: req.db).flatMap { savedPlayer in
            guard let savedPlayer = savedPlayer else {
                return req.eventLoop.future(
                    error: Abort(
                        .notFound,
                        reason: "Player not found after creation."
                    )
                )
            }

            guard let teamID = savedPlayer.$team.id else {
                return req.eventLoop.future(
                    error: Abort(
                        .badRequest,
                        reason: "Player must belong to a team."
                    )
                )
            }

            return Team.find(teamID, on: req.db).flatMap { team in
                guard let team = team else {
                    return req.eventLoop.future(
                        error: Abort(.notFound, reason: "Team not found.")
                    )
                }

                // Generate invoice number: current year + random 5-digit number
                let year = Calendar.current.component(.year, from: Date.viennaNow)
                let randomFiveDigitNumber = String(
                    format: "%05d",
                    Int.random(in: 0..<100_000)
                )
                let invoiceNumber = "\(year)\(randomFiveDigitNumber)"

                let rechnungAmount: Double = -5.0

                let rechnung = Rechnung(
                    team: team.id!,
                    teamName: team.teamName,
                    number: invoiceNumber,
                    summ: rechnungAmount,
                    topay: nil,
                    previousBalance: team.balance,
                    kennzeichen: team.teamName + " " + savedPlayer.sid + ": Anmeldung"
                )

                return rechnung.save(on: req.db).flatMap {
                    if let currentBalance = team.balance {
                        team.balance = currentBalance - 5
                    } else {
                        team.balance = -5
                    }

                    return team.save(on: req.db).map {
                        req.logger.info(
                            "Rechnung created and team balance updated for player \(savedPlayer.id?.uuidString ?? "unknown")"
                        )
                        return savedPlayer
                    }
                }
            }
        }
    }

    // MARK: - Small helpers

    /// Random 6-digit SID as string.
    private func generateSixDigitSID() -> String {
        let value = Int.random(in: 100_000..<1_000_000)
        return String(value)
    }

    /// "yyyy-MM-dd" in Europe/Vienna, to match your registerDate style.
    private func currentRegisterDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Europe/Vienna")
        return formatter.string(from: Date())
    }
}
