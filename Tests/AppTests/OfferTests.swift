@testable import App
import XCTVapor

final class OfferTests: XCTestCase {
    private func input(start: Date = Date(timeIntervalSince1970: 100), end: Date = Date(timeIntervalSince1970: 200), url: String = "https://example.com/deal", description: String = "Member discount") -> OfferInput {
        OfferInput(startsAt: start, endsAt: end, companyName: " Company ", logo: "https://example.com/logo.png", affiliateUrl: url, description: description)
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
