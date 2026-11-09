import Foundation
import XCTVapor
@testable import App

final class JerseyKitGenerationTests: XCTestCase {
    private func fixture(_ name: String = "jersey-kit-transparent") throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func image(_ data: Data, filename: String = "jersey.png") -> File {
        File(data: ByteBuffer(data: data), filename: filename)
    }

    private func response(_ png: Data) throws -> ClientResponse {
        let body = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]])
        return .init(status: .ok, body: ByteBuffer(data: body))
    }

    private func service(_ client: Client, key: String = "test-key") -> JerseyKitGenerationService {
        .init(client: client, configuration: .init(apiKey: key))
    }

    func testImageInImageOutUsesBundledReferenceAndFixedSettings() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        let png = try fixture()
        let client = JerseyKitMockClient(eventLoop: app.eventLoopGroup.next(), responses: [try response(png)])
        // An untrusted filename must not control the actual input MIME type.
        let result = try await service(client).generate(image: image(png, filename: "untrusted.txt"))
        XCTAssertEqual(result.filename, "generated-kit.png")
        XCTAssertEqual(result.contentType, .png)
        XCTAssertEqual(Data(buffer: result.data), png)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(request.method, .POST)
        XCTAssertEqual(request.url.string, "https://api.openai.com/v1/images/edits")
        XCTAssertEqual(request.headers.bearerAuthorization?.token, "test-key")
        XCTAssertEqual(request.timeout, .seconds(180))
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any])
        XCTAssertEqual(json["background"] as? String, "transparent")
        XCTAssertEqual(json["output_format"] as? String, "png")
        XCTAssertEqual(json["size"] as? String, "1024x1536")
        XCTAssertEqual(json["n"] as? Int, 1)
        XCTAssertEqual(json["model"] as? String, "gpt-image-2.5-sunburst-2026-09-08")
        XCTAssertEqual(json["prompt"] as? String, JerseyKitGenerationService.prompt)
        let images = try XCTUnwrap(json["images"] as? [[String: String]])
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0]["image_url"], "data:image/png;base64,\(png.base64EncodedString())")
        let reference = try XCTUnwrap(images[1]["image_url"])
        XCTAssertTrue(reference.hasPrefix("data:image/png;base64,"))
        XCTAssertNotEqual(reference, images[0]["image_url"])
    }

    func testInvalidInputsFailBeforeProviderCall() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        let client = JerseyKitMockClient(eventLoop: app.eventLoopGroup.next(), responses: [])
        var oversized = Data([137, 80, 78, 71, 13, 10, 26, 10])
        oversized.append(Data(repeating: 0, count: 10 * 1024 * 1024))
        for (data, status) in [(Data(), HTTPStatus.badRequest),
                               (Data("not an image".utf8), .unsupportedMediaType),
                               (Data("%PDF-1.4".utf8), .unsupportedMediaType),
                               (oversized, .payloadTooLarge)] {
            do {
                _ = try await service(client).generate(image: image(data))
                XCTFail("Expected upload rejection")
            } catch let error as AbortError { XCTAssertEqual(error.status, status) }
        }
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testMissingConfigurationAndInvalidReferenceFailBeforeProviderCall() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        let client = JerseyKitMockClient(eventLoop: app.eventLoopGroup.next(), responses: [])
        let input = image(try fixture())
        var invalidReference = service(client)
        invalidReference.layoutReference = image(Data("broken".utf8))
        for generator in [service(client, key: ""), invalidReference] {
            do {
                _ = try await generator.generate(image: input)
                XCTFail("Expected configuration rejection")
            } catch let error as AbortError { XCTAssertEqual(error.status, .serviceUnavailable) }
        }
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testMalformedProviderResponsesAreRejected() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        for body in ["not JSON", "{}", "{\"data\":[]}", "{\"data\":[{\"b64_json\":\"!\"}]}",
                     "{\"data\":[{\"b64_json\":\"aGVsbG8=\"}]}"] {
            let client = JerseyKitMockClient(eventLoop: app.eventLoopGroup.next(), responses: [
                .init(status: .ok, body: ByteBuffer(string: body))
            ])
            do {
                _ = try await service(client).generate(image: image(try fixture()))
                XCTFail("Expected invalid response rejection")
            } catch let error as AbortError { XCTAssertEqual(error.status, .badGateway) }
        }
    }

    func testOpaqueInvisibleAndCorruptImagesAreRejected() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        let input = try fixture()
        var corrupt = input
        corrupt[corrupt.count / 2] ^= 1
        var trailing = input
        trailing.append(0)
        for data in [try fixture("jersey-kit-opaque"), try fixture("jersey-kit-invisible"),
                     corrupt, Data(input.prefix(50)), trailing] {
            let client = JerseyKitMockClient(eventLoop: app.eventLoopGroup.next(), responses: [try response(data)])
            do {
                _ = try await service(client).generate(image: image(input))
                XCTFail("Expected invalid PNG rejection")
            } catch let error as AbortError { XCTAssertEqual(error.status, .badGateway) }
        }
    }

    func testProviderErrorIsSanitizedAndNotRetriedForAuthenticationFailure() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        let client = JerseyKitMockClient(eventLoop: app.eventLoopGroup.next(), responses: [
            .init(status: .unauthorized, body: ByteBuffer(string: "secret-provider-details"))
        ])
        do {
            _ = try await service(client).generate(image: image(try fixture()))
            XCTFail("Expected provider error")
        } catch let error as AbortError {
            XCTAssertEqual(error.status, .badGateway)
            XCTAssertFalse(error.reason.contains("secret"))
        }
        XCTAssertEqual(client.requests.count, 1)
    }

    func testTransientProviderResponseIsRetriedOnce() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        let png = try fixture()
        let client = JerseyKitMockClient(eventLoop: app.eventLoopGroup.next(), responses: [
            .init(status: .tooManyRequests, headers: ["Retry-After": "0"]), try response(png)
        ])
        let generated = try await service(client).generate(image: image(png))
        XCTAssertEqual(Data(buffer: generated.data), png)
        XCTAssertEqual(client.requests.count, 2)
    }

    func testTransportFailureIsSanitizedAndNotRetried() async throws {
        let app = Application(.testing); defer { app.shutdown() }
        let client = JerseyKitMockClient(eventLoop: app.eventLoopGroup.next(), responses: [])
        do {
            _ = try await service(client).generate(image: image(try fixture()))
            XCTFail("Expected transport failure")
        } catch let error as AbortError { XCTAssertEqual(error.status, .badGateway) }
        XCTAssertEqual(client.requests.count, 1)
    }

    func testConfigurationUsesExistingKeyAndBoundsTimeout() {
        let values = ["OPENAI_API_KEY": "shared-key", "JERSEY_KIT_IMAGE_MODEL": "configured-model", "JERSEY_KIT_TIMEOUT_SECONDS": "9999"]
        let config = JerseyKitGenerationService.Configuration.load { values[$0] }
        XCTAssertEqual(config.apiKey, "shared-key")
        XCTAssertEqual(config.model, "configured-model")
        XCTAssertEqual(config.timeoutSeconds, 600)
    }
}

private final class JerseyKitMockClient: Client, @unchecked Sendable {
    let eventLoop: EventLoop
    private let lock = NSLock()
    private var captured: [ClientRequest] = []
    private var responses: [ClientResponse]
    var requests: [ClientRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    init(eventLoop: EventLoop, responses: [ClientResponse]) {
        self.eventLoop = eventLoop; self.responses = responses
    }

    func delegating(to eventLoop: EventLoop) -> Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        lock.lock(); defer { lock.unlock() }
        captured.append(request)
        guard !responses.isEmpty else { return eventLoop.makeFailedFuture(Abort(.gatewayTimeout)) }
        return eventLoop.makeSucceededFuture(responses.removeFirst())
    }
}
