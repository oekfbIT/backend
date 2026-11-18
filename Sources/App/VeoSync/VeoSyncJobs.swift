import Foundation
import Fluent
import Vapor

/// One manual "connect this match to Veo" run started from the admin.
final class VeoSyncJob: Model {
    static let schema = "veo_sync_jobs"

    @ID(key: .id) var id: UUID?
    @Field(key: "match") var matchID: UUID
    @OptionalField(key: "veo_slug") var veoSlug: String?
    @Field(key: "with_video") var withVideo: Bool
    @Field(key: "status") var status: String          // running | completed | failed
    @Field(key: "log") var log: [String]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
    init(matchID: UUID, veoSlug: String?, withVideo: Bool) {
        self.matchID = matchID; self.veoSlug = veoSlug; self.withVideo = withVideo
        self.status = "running"; self.log = []
    }
}

struct VeoSyncJobResponse: Content {
    let id: UUID?
    let status: String
    let veoSlug: String?
    let withVideo: Bool
    let log: [String]
    let createdAt: Date?
    let updatedAt: Date?
    init(_ j: VeoSyncJob) {
        id = j.id; status = j.status; veoSlug = j.veoSlug; withVideo = j.withVideo
        log = j.log; createdAt = j.createdAt; updatedAt = j.updatedAt
    }
}

/// Starts tools/veo-sync as a child process (login shell, so node/npm/ffmpeg from Homebrew are on PATH)
/// and streams its output into the job document every few seconds.
enum VeoSyncRunner {
    actor Buffer {
        var lines: [String] = []
        func append(_ text: String) { lines += text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
        func snapshot() -> [String] { Array(lines.suffix(300)) }
    }

    static func workerDirectory(_ app: Application) -> String {
        Environment.get("VEO_SYNC_DIR") ?? (app.directory.workingDirectory + "tools/veo-sync")
    }

    static func start(job: VeoSyncJob, app: Application) throws {
        let jobID = try job.requireID()
        let dir = workerDirectory(app)
        guard FileManager.default.fileExists(atPath: dir + "/package.json") else {
            throw Abort(.serviceUnavailable, reason: "Veo-Worker nicht gefunden: \(dir)")
        }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var command = "cd \(quote(dir)) && "
        command += "( [ -d node_modules ] || (echo 'Installiere Abhängigkeiten…' && npm install --no-fund --no-audit && npx playwright install chromium) ) && "
        command += "node src/index.mjs match \(job.matchID.uuidString)"
        if let slug = job.veoSlug { command += " --slug \(quote(slug))" }
        if !job.withVideo { command += " --no-video" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["VEO_SYNC_BACKEND_URL"] = Environment.get("VEO_SYNC_BACKEND_URL") ?? "http://localhost:8080"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await buffer.append(text) }
        }

        let db = app.db
        // Flush the log every 3 s while running.
        let flusher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let j = try? await VeoSyncJob.find(jobID, on: db) { j.log = await buffer.snapshot(); try? await j.save(on: db) }
            }
        }
        process.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let code = finished.terminationStatus
            Task {
                flusher.cancel()
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let j = try? await VeoSyncJob.find(jobID, on: db) else { return }
                await buffer.append(code == 0 ? "✓ Fertig" : "✗ Beendet mit Code \(code)")
                j.log = await buffer.snapshot()
                j.status = code == 0 ? "completed" : "failed"
                try? await j.save(on: db)
            }
        }
        try process.run()
    }
}
