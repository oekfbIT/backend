import Vapor
// MARK: - FirebaseManager + models

final class FirebaseManager {
    private let client: Client
    private let apiKey: String
    private let email: String
    private let password: String
    private let projectId: String

    private var idToken: String?

    init(
        client: Client,
        apiKey: String,
        email: String,
        password: String,
        projectId: String
    ) {
        self.client = client
        self.apiKey = apiKey
        self.email = email
        self.password = password
        self.projectId = projectId
    }

    func authenticate() -> EventLoopFuture<Void> {
        let url =
            "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(apiKey)"

        struct RequestBody: Content {
            let email: String
            let password: String
            let returnSecureToken: Bool
        }

        let requestBody = RequestBody(
            email: email,
            password: password,
            returnSecureToken: true
        )

        return client.post(
            URI(string: url),
            headers: ["Content-Type": "application/json"]
        ) { req in
            try req.content.encode(requestBody)
        }.flatMapThrowing { response in
            let data = try response.content.decode(AuthResponse.self)
            self.idToken = data.idToken
        }
    }

    func uploadFile(file: File, to path: String) -> EventLoopFuture<String> {
        guard let idToken = idToken else {
            return client.eventLoop.future(error: Abort(.unauthorized))
        }

        let url =
            "https://firebasestorage.googleapis.com/v0/b/\(projectId).appspot.com/o?name=\(path)"

        return client.post(
            URI(string: url),
            headers: [
                "Authorization": "Bearer \(idToken)",
                "Content-Type": file.contentType?.description
                    ?? "application/octet-stream",
            ]
        ) { req in
            req.body = file.data
        }.flatMapThrowing { response in
            guard response.status == .ok else {
                throw Abort(.internalServerError, reason: "File upload failed")
            }

            let data = try response.content.decode(UploadResponse.self)

            guard let token = data.downloadTokens else {
                throw Abort(
                    .internalServerError,
                    reason: "Missing download token from Firebase response"
                )
            }

            return "https://firebasestorage.googleapis.com/v0/b/\(self.projectId).appspot.com/o/\(path)?alt=media&token=\(token)"
        }
    }
}

struct AuthResponse: Content {
    let idToken: String
}

struct UploadResponse: Content {
    let name: String
    let bucket: String
    let generation: String
    let metageneration: String
    let contentType: String
    let timeCreated: String
    let updated: String
    let storageClass: String
    let size: String
    let md5Hash: String

    // These are not always present → optional
    let contentEncoding: String?
    let contentDisposition: String?
    let contentLanguage: String?
    let cacheControl: String?

    // May also be absent in some error cases → optional + checked
    let downloadTokens: String?
}

// MARK: - Application storage hook

extension Application {
    private struct FirebaseManagerKey: StorageKey {
        typealias Value = FirebaseManager
    }

    var firebaseManager: FirebaseManager {
        get {
            guard let firebaseManager = self.storage[FirebaseManagerKey.self] else {
                fatalError("FirebaseManager not set.")
            }
            return firebaseManager
        }
        set {
            self.storage[FirebaseManagerKey.self] = newValue
        }
    }
}





