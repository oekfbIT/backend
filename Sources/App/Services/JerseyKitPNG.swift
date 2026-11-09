import Foundation
import Vapor
import CZlib

/// Bounded validation of the requested non-interlaced, 8-bit RGBA PNG output.
/// Checks chunk CRCs, decompresses every scanline and inspects actual alpha values.
enum JerseyKitPNG {
    static func validate(_ data: Data) throws {
        func invalid() -> Abort { Abort(.badGateway, reason: "Generated kit is not a valid 1024x1536 RGBA PNG.") }
        let bytes = [UInt8](data)
        guard bytes.count >= 33, bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw invalid() }
        func word(_ offset: Int) -> Int {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        var offset = 8, compressed = [UInt8](), headerSeen = false, ended = false
        var dataSeen = false, dataClosed = false
        while offset + 12 <= bytes.count {
            let length = word(offset)
            guard length <= bytes.count - offset - 12 else { throw invalid() }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            let start = offset + 8, end = start + length
            let actualCRC = bytes.withUnsafeBufferPointer {
                crc32(0, $0.baseAddress!.advanced(by: offset + 4), uInt(length + 4))
            }
            guard actualCRC == uLong(word(end)), headerSeen || type == "IHDR" else { throw invalid() }
            switch type {
            case "IHDR":
                guard !headerSeen, length == 13, word(start) == 1024, word(start + 4) == 1536,
                      bytes[start + 8] == 8, bytes[start + 9] == 6,
                      bytes[start + 10] == 0, bytes[start + 11] == 0, bytes[start + 12] == 0 else { throw invalid() }
                headerSeen = true
            case "IDAT":
                guard !dataClosed else { throw invalid() }
                dataSeen = true
                compressed.append(contentsOf: bytes[start..<end])
            case "IEND":
                guard length == 0, dataSeen, end + 4 == bytes.count else { throw invalid() }
                ended = true
            default:
                // Unknown critical chunks (including palette/transparency changes) are rejected.
                guard bytes[offset + 4] & 0x20 != 0 else { throw invalid() }
                if dataSeen { dataClosed = true }
            }
            offset = end + 4
            if ended { break }
        }
        guard ended, !compressed.isEmpty else { throw invalid() }
        let stride = 1024 * 4, expected = (stride + 1) * 1536
        var scanlines = [UInt8](repeating: 0, count: expected)
        var decodedSize = uLongf(expected)
        let status = scanlines.withUnsafeMutableBufferPointer { destination in
            compressed.withUnsafeBufferPointer { source in
                uncompress(destination.baseAddress!, &decodedSize, source.baseAddress!, uLong(source.count))
            }
        }
        guard status == Z_OK, decodedSize == expected else { throw invalid() }

        var previous = [UInt8](repeating: 0, count: stride)
        var current = previous, hasTransparentBackground = false, hasVisiblePixels = false
        for y in 0..<1536 {
            let start = y * (stride + 1)
            let filter = scanlines[start]
            guard filter <= 4 else { throw invalid() }
            for x in 0..<stride {
                let left = x >= 4 ? Int(current[x - 4]) : 0
                let above = Int(previous[x])
                let upperLeft = x >= 4 ? Int(previous[x - 4]) : 0
                let predictor: Int
                switch filter {
                case 0: predictor = 0
                case 1: predictor = left
                case 2: predictor = above
                case 3: predictor = (left + above) / 2
                default:
                    let p = left + above - upperLeft
                    let a = abs(p - left), b = abs(p - above), c = abs(p - upperLeft)
                    predictor = a <= b && a <= c ? left : (b <= c ? above : upperLeft)
                }
                current[x] = scanlines[start + 1 + x] &+ UInt8(predictor)
                if x % 4 == 3 {
                    // Require a transparent canvas edge as well as visible garment pixels.
                    if y == 0 || y == 1535 || x == 3 || x == stride - 1 {
                        hasTransparentBackground = hasTransparentBackground || current[x] == 0
                    }
                    hasVisiblePixels = hasVisiblePixels || current[x] > 0
                }
            }
            swap(&previous, &current)
        }
        guard hasTransparentBackground, hasVisiblePixels else {
            throw Abort(.badGateway, reason: "Generated kit has no transparent background or is entirely invisible.")
        }
    }
}
