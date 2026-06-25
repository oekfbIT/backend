//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 08.04.26.
//

import Foundation

//Auth
protocol DBUser {
    let id: UUID
    var roles: [DBUserRole] // While most will be only one, some may be multiple and this will access both views in the app as an array
}
protocol DBAccessToken {
    enum SessionSource: Int, Content {
        case signup = 0
        case login = 1
    }

    var id: UUID
    var user: DBUser.ID
    var value: String
    var source: SessionSource
    var expiresAt: Date?
    var updatedAt: Date?
}
enum DBUserRole {
    case team, player, admin, referee
}
protocol DBVerification {}
//CORE
protocol DBTeam {}
protocol DBPlayer {}
protocol DBTransfer {}
protocol DBLeague {}
protocol DBSeason {
//    include season settings including transfer window, penalty prices, etc, registration date,
}
protocol DBMatch {}
protocol DBMatchEvent {}
protocol DBAchievement {}
protocol DBStadium {}
protocol DBStadiumBookingSlot {}

//Voting
protocol DBVoteBox {}
protocol DBVoteItem {}

//Sponsors
protocol DBSponsor {}

//Communication
protocol DBInbox {}
protocol DBConversation {}
protocol DBFile {
    // Recoding,  video,  images, docs such pdf
    // All infos like mimetype
}
protocol DBMessage {}
protocol DBFollowSubscription {}
protocol DBDeviceToken {}

//Referee
protocol DBReferee {}

//Clients
protocol DBNewsItem {}
protocol DBHighlight {}

//Disciplinary
protocol DBDisciplinaryCase {}
protocol DBDisciplinaryPenalty {}

//Finances
protocol DBInvoice {
//    in / out then summ, if its manual or via stripe
}
protocol DBWallet {}
protocol DBContract {}

// Registrations
protocol DBClubRegistration {}
protocol DBPlayerPoolRegistration {}

// Admin
protocol DBDataUpdateRequest {
//    user image, eligibility, matchpostpone, team jersey update
}

//Managers
protocol StatGateway {}
protocol AIGateway {}
protocol FirebaseGateway {}
protocol NotificationGateway {}
protocol PaymentGateway {} // Manual and Stripe Manager
protocol AnalyticsGateway {}

