//
//
//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.
//

import Vapor
import Fluent

struct UserSignup: Content {
    public let id: String
    public let firstName: String
    public let lastName: String
    public let email: String
    public let tel: String?
    public let password: String
    public let type: UserType
    
    init(id: String, firstName: String, lastName: String, email: String, password: String, type: UserType, tel: String?) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.tel = tel
        self.password = password
        self.type = type
    }
}

struct NewSession: Content {
    let token: String
    let user: User.Public
}

struct AppSession: Content {
    let token: String
    let user: User.Public
    let teams: [AppSessionTeam]
}

/// The authenticated team-session payload is intentionally allowlisted. Never
/// return a Fluent `Team` here: it contains login credentials, contact details,
/// deposits and other administrative fields.
struct AppSessionTeam: Content {
    let id: UUID?
    let sid: String?
    let league: UUID?
    let leagueCode: String?
    let points: Int
    let logo: String
    let coverimg: String?
    let teamName: String
    let shortName: String?
    let foundationYear: String?
    let membershipSince: String?
    let averageAge: String
    let coach: PublicTrainer?
    let altCoach: PublicTrainer?
    let captain: String?
    let trikot: Trikot
    let balance: Double?
    let referCode: String?
    let cancelled: Int?
    let postponed: Int?
    let overdraft: Bool?
    let overdraftDate: Date?
    let players: [Player.Public]
}

extension Team {
    func asAppSessionTeam() -> AppSessionTeam {
        AppSessionTeam(
            id: id,
            sid: sid,
            league: $league.id,
            leagueCode: leagueCode,
            points: points,
            logo: logo,
            coverimg: coverimg,
            teamName: teamName,
            shortName: shortName,
            foundationYear: foundationYear,
            membershipSince: membershipSince,
            averageAge: averageAge,
            coach: coach?.asPublic(),
            altCoach: altCoach?.asPublic(),
            captain: captain,
            trikot: trikot,
            balance: balance,
            referCode: referCode,
            cancelled: cancelled,
            postponed: postponed,
            overdraft: overdraft,
            overdraftDate: overdraftDate,
            players: players.map { $0.asPublic() }
        )
    }
}
