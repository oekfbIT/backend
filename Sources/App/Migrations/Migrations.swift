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
    NewsItemMigration()
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
