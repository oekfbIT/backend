import Foundation
import Vapor

// MARK: - Firebase Auth + Storage

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

    // Sign in with email / password to get idToken
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

    // Uploads a File to Firebase Storage and returns a public download URL
    func uploadFile(file: File, to path: String) -> EventLoopFuture<String> {
        guard let idToken = idToken else {
            return client.eventLoop.future(error: Abort(.unauthorized))
        }

        // Encode object name for use in Firebase REST API
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/") // we want "/" as "%2F"
        let encodedName =
            path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path

        let url =
            "https://firebasestorage.googleapis.com/v0/b/\(projectId).appspot.com/o?name=\(encodedName)"

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

            // Final download URL (this is what you store in Player.image / identification)
            let downloadURL =
                "https://firebasestorage.googleapis.com/v0/b/\(self.projectId).appspot.com/o/\(encodedName)?alt=media&token=\(token)"

            return downloadURL
        }
    }
}

// MARK: - DTOs

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

    // Not guaranteed to be present on every response → optional
    let contentEncoding: String?
    let contentDisposition: String?
    let contentLanguage: String?
    let cacheControl: String?

    // Defensive: can be missing in some edge cases
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
