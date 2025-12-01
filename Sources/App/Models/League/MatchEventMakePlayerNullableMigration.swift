//
//  File.swift
//  oekfbbackend
//
//  Created by Alon Yakoby on 01.12.25.
//

import Foundation
// MatchEventMakePlayerNullableMigration.swift

import Fluent

struct MatchEventMakePlayerNullableMigration: Migration {
    func prepare(on database: Database) -> EventLoopFuture<Void> {
        return database.schema(MatchEvent.schema)
            .updateField(MatchEvent.FieldKeys.playerId, .uuid)
            .update()   // <- this returns EventLoopFuture<Void>
    }

    func revert(on database: Database) -> EventLoopFuture<Void> {
        // Either no-op or restore to NOT NULL depending on how strict you want to be.
        return database.eventLoop.makeSucceededFuture(())
    }
}
