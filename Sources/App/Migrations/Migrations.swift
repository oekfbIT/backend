//  Copyright © 2023.
//  Alon Yakobichvili
//  All rights reserved.

import Fluent

let app_migrations: [Migration] = [
    UserMigration(),
    TeamMigration(),
    PlayerMigration(),
    LeagueMigration(),
    MatchMigration(),
    StadiumMigration(),
    UserVerificationTokenMigration(),
    TokenMigration(),
    ConversationMigration(),
    NewsItemMigration(),
    RechnungMigration(),
    TransferMigration(),
    TransferSettingsMigration(),
    MatchEventMigration()
]

struct UserMigration { }
struct TeamMigration { }
struct PlayerMigration { }
struct LeagueMigration { }
struct MatchMigration { }
struct StadiumMigration { }
struct UserVerificationTokenMigration { }
struct TokenMigration { }
struct TeamRegistrationMigration { }
struct ConversationMigration { }
struct NewsItemMigration {}
struct RechnungMigration { }
struct TransferMigration { }
struct TransferSettingsMigration { }
struct MatchEventMigration { }
