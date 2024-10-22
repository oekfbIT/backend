import Vapor
import Fluent
import Queues

struct TestJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        context.logger.info("Test Job is running every second.")
        print("Test Job is running every second.")
    }
}

struct UnlockPlayerJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        context.logger.info("Unlock Job is running.")
        print("Unlock Job is running.")

        // Job logic
        // Get all the players with eligibility Gesperrt, Check if their blockdate has passed, if yes set their eligibility to Spielberechtigt
        let players = try await Player.query(on: context.application.db)
            .filter(\.$eligibility == .Gesperrt)
            .filter(\.$blockdate <= Date())
            .all()
        
        for player in players {
            player.eligibility = .Spielberechtigt
            try await player.save(on: context.application.db)
            context.logger.info("Player \(player.name) eligibility updated to Spielberechtigt.")
        }
    }
}

struct DressLockJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        context.logger.info("Dress Lock Job is running.")
        print("Dress Lock Job is running.")

        // Job logic
        // Get the first item for TransferSettings (as there should be only 1 on the system) and set the isDressChangeOpen to false
        if let transferSetting = try await TransferSettings.query(on: context.application.db).first() {
            transferSetting.isDressChangeOpen = false
            try await transferSetting.save(on: context.application.db)
            context.logger.info("TransferSettings isDressChangeOpen set to false.")
        }
    }
}

struct DressUnlockJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        context.logger.info("Dress Unlock Job is running.")
        print("Dress Unlock Job is running.")

        // Job logic
        // Get the first item for TransferSettings (as there should be only 1 on the system) and set the isDressChangeOpen to true
        if let transferSetting = try await TransferSettings.query(on: context.application.db).first() {
            transferSetting.isDressChangeOpen = true
            try await transferSetting.save(on: context.application.db)
            context.logger.info("TransferSettings isDressChangeOpen set to true.")
        }
    }
}