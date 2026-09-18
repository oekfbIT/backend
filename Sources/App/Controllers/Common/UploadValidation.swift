import Vapor

enum UploadValidation {
    enum Kind: Hashable {
        case jpeg
        case png
        case pdf
    }

    static func validate(
        _ file: File,
        allowed: Set<Kind>,
        maximumBytes: Int = 10 * 1024 * 1024
    ) throws {
        let count = file.data.readableBytes
        guard count > 0 else {
            throw Abort(.badRequest, reason: "The uploaded file is empty.")
        }
        guard count <= maximumBytes else {
            throw Abort(.payloadTooLarge, reason: "The uploaded file exceeds the 10 MB limit.")
        }

        let bytes = Array(file.data.readableBytesView.prefix(8))
        let contentType = file.contentType?.description.lowercased()
        let kind: Kind
        switch contentType {
        case "application/pdf":
            guard bytes.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) else {
                throw Abort(.unsupportedMediaType, reason: "The file content does not match its PDF type.")
            }
            kind = .pdf
        case "image/png":
            guard bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
                throw Abort(.unsupportedMediaType, reason: "The file content does not match its PNG type.")
            }
            kind = .png
        case "image/jpeg", "image/jpg":
            guard bytes.starts(with: [0xFF, 0xD8, 0xFF]) else {
                throw Abort(.unsupportedMediaType, reason: "The file content does not match its JPEG type.")
            }
            kind = .jpeg
        default:
            throw Abort(.unsupportedMediaType, reason: "Only PDF, PNG, and JPEG files are supported.")
        }

        guard allowed.contains(kind) else {
            throw Abort(.unsupportedMediaType, reason: "This file type is not allowed for this upload.")
        }
    }
}
