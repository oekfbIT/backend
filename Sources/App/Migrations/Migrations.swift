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
    MatchEventMigration(),
    StrafsenatMigration(),
    MatchAchivementMigration(),
    PostponeRequestMigration(),
    RuleMigration(),
    CreateDeviceToken(),
    CreatePushNotificationLog(),
    CreateSavedPushDevice(),
    SponsorMigration(),
    VerificationCodeMigration(),
    CreateFollowSubscription(),
    VoteItemMigration(),
    LegalSectionMigration(),
    StaticPageContentSeedMigration(),
    SponsorDisplayFieldsMigration(),
    SeasonTeamMigration(),
    StatsQueryIndexesMigration()
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
struct StrafsenatMigration { }
struct MatchAchivementMigration {}
struct PostponeRequestMigration {}
struct RuleMigration {}
struct CreateDeviceToken {}
struct CreatePushNotificationLog {}
struct CreateSavedPushDevice {}
struct SponsorMigration {}
struct VerificationCodeMigration {}
struct VoteItemMigration {}
