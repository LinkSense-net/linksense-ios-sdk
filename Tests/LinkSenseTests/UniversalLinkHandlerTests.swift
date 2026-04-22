import XCTest
@testable import LinkSense

final class UniversalLinkHandlerTests: XCTestCase {
    func test_extracts_valid_click_id_from_query() {
        let url = URL(string: "https://acme.linksense.net/signup?click_id=abcDEF12345_&utm_source=x")!
        XCTAssertEqual(UniversalLinkHandler.extractClickId(from: url), "abcDEF12345_")
    }

    func test_ignores_non_click_id_query_params() {
        let url = URL(string: "https://acme.linksense.net/signup?utm_source=x&utm_medium=cpc")!
        XCTAssertNil(UniversalLinkHandler.extractClickId(from: url))
    }

    func test_rejects_wrong_length_click_id() {
        let url = URL(string: "https://acme.linksense.net/?click_id=too-short")!
        XCTAssertNil(UniversalLinkHandler.extractClickId(from: url))
    }

    func test_rejects_click_id_with_invalid_chars() {
        let url = URL(string: "https://acme.linksense.net/?click_id=abc$DEF12345")!
        XCTAssertNil(UniversalLinkHandler.extractClickId(from: url))
    }

    func test_accepts_click_id_with_all_url_safe_chars() {
        let url = URL(string: "https://acme.linksense.net/?click_id=ab-CD_12xYZ9")!
        XCTAssertEqual(UniversalLinkHandler.extractClickId(from: url), "ab-CD_12xYZ9")
    }
}
