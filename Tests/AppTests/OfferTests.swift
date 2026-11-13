@testable import App
import XCTVapor

final class OfferTests: XCTestCase {
    private func input(start: Date = Date(timeIntervalSince1970: 100), end: Date = Date(timeIntervalSince1970: 200), url: String = "https://example.com/deal", description: String = "Member discount") -> OfferInput {
        OfferInput(startsAt: start, endsAt: end, companyName: " Company ", logo: "https://example.com/logo.png", affiliateUrl: url, description: description)
    }

    func testDecodesAdminDatePayload() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let payload = Data(#"{"starts_at":"2026-11-10T14:35:00Z","ends_at":"2026-12-30T23:00:00Z","company_name":"Team11Sports","logo":"https://example.com/logo.png","affiliate_url":"https://example.com/deal","description":"Member discount"}"#.utf8)
        let body = try decoder.decode(OfferInput.self, from: payload)
        let offer = Offer()
        try body.apply(to: offer)
        XCTAssertEqual(offer.companyName, "Team11Sports")
        XCTAssertGreaterThan(offer.endsAt, offer.startsAt)
        XCTAssertEqual(offer.startsAt, ISO8601DateFormatter().date(from: "2026-11-10T14:35:00Z"))
    }

    func testValidOfferPreservesDatesAndNormalizesName() throws {
        let offer = Offer()
        try input().apply(to: offer)
        XCTAssertEqual(offer.companyName, "Company")
        XCTAssertEqual(offer.startsAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(offer.endsAt, Date(timeIntervalSince1970: 200))
    }

    func testRejectsEmptyOrReversedRange() {
        XCTAssertThrowsError(try input(end: Date(timeIntervalSince1970: 100)).apply(to: Offer()))
        XCTAssertThrowsError(try input(end: Date(timeIntervalSince1970: 99)).apply(to: Offer()))
    }

    func testRejectsUnsafeLinkAndBlankDescription() {
        XCTAssertThrowsError(try input(url: "javascript:alert(1)").apply(to: Offer()))
        XCTAssertThrowsError(try input(description: " \n ").apply(to: Offer()))
    }
}
