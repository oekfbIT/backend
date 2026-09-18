import Foundation
import Vapor

extension AdminController {
    struct AdminUploadRequest: Content {
        let file: File
        let path: String
        let filename: String
    }

    struct AdminUploadResponse: Content {
        let url: String
    }

    func setupUploadRoutes(on admin: RoutesBuilder) {
        admin.on(
            .POST,
            "uploads",
            body: .collect(maxSize: "20mb"),
            use: uploadAdminFile
        )
    }

    func uploadAdminFile(req: Request) async throws -> AdminUploadResponse {
        let upload = try req.content.decode(AdminUploadRequest.self)

        guard upload.file.data.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "The uploaded file is empty.")
        }

        let path = try validatedUploadPath(upload.path)
        let filename = try validatedUploadFilename(upload.filename)
        let fileExtension = try validatedUploadType(upload.file)
        let destination = "\(path)/\(filename).\(fileExtension)"

        let firebase = req.application.firebaseManager
        try await firebase.authenticate().get()
        let url = try await firebase.uploadFile(file: upload.file, to: destination).get()

        return AdminUploadResponse(url: url)
    }

    private func validatedUploadPath(_ rawPath: String) throws -> String {
        let path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, path.utf8.count <= 512 else {
            throw Abort(.badRequest, reason: "Invalid upload path.")
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ isSafeUploadSegment(String($0)) }) else {
            throw Abort(.badRequest, reason: "Invalid upload path.")
        }

        return path
    }

    private func validatedUploadFilename(_ rawFilename: String) throws -> String {
        let filename = rawFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard filename.utf8.count <= 200, isSafeUploadSegment(filename) else {
            throw Abort(.badRequest, reason: "Invalid upload filename.")
        }

        return filename
    }

    private func isSafeUploadSegment(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\?#%"))
        return value.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    private func validatedUploadType(_ file: File) throws -> String {
        let bytes = Array(file.data.readableBytesView.prefix(8))
        let contentType = file.contentType?.description.lowercased()

        switch contentType {
        case "application/pdf":
            guard bytes.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) else {
                throw Abort(.unsupportedMediaType, reason: "The file content does not match its PDF type.")
            }
            return "pdf"
        case "image/png":
            guard bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
                throw Abort(.unsupportedMediaType, reason: "The file content does not match its PNG type.")
            }
            return "png"
        case "image/jpeg", "image/jpg":
            guard bytes.starts(with: [0xFF, 0xD8, 0xFF]) else {
                throw Abort(.unsupportedMediaType, reason: "The file content does not match its JPEG type.")
            }
            return "jpeg"
        default:
            throw Abort(.unsupportedMediaType, reason: "Only PDF, PNG, and JPEG files are supported.")
        }
    }
}
