import XCTest
@testable import LinkSense

/// The pasteboard is attacker-adjacent input: whatever the user last copied,
/// from any app. These pin what we will and will not treat as attribution.
final class ClipboardReaderTests: XCTestCase {

    func testAcceptsTheHttpsPayloadWeWrite() {
        XCTAssertEqual(
            ClipboardReader.extract(from: "https://acme.linksense.net/sale?click_id=abcDEF12345_"),
            "abcDEF12345_"
        )
    }

    func testAcceptsAPayloadWithOtherQueryParams() {
        XCTAssertEqual(
            ClipboardReader.extract(from: "https://acme.linksense.net/s?utm_source=x&click_id=abcDEF12345_&z=1"),
            "abcDEF12345_"
        )
    }

    func testToleratesSurroundingWhitespace() {
        // Copying from a text selection routinely picks up a trailing newline.
        XCTAssertEqual(
            ClipboardReader.extract(from: "  https://acme.linksense.net/s?click_id=abcDEF12345_\n"),
            "abcDEF12345_"
        )
    }

    func testRejectsOrdinaryClipboardContent() {
        // The cases that matter: someone's password, a note, a plain link.
        for value in [
            "hunter2",
            "https://example.com/nothing-to-do-with-us",
            "Remember to buy milk",
            "",
            "   ",
        ] {
            XCTAssertNil(ClipboardReader.extract(from: value), "should reject \(value.debugDescription)")
        }
    }

    func testRejectsNil() {
        XCTAssertNil(ClipboardReader.extract(from: nil))
    }

    func testRejectsAMalformedClickId() {
        // Wrong length and out-of-alphabet both fail the server's own regex, so
        // sending them would just burn a request.
        XCTAssertNil(ClipboardReader.extract(from: "https://a.b/c?click_id=tooshort"))
        XCTAssertNil(ClipboardReader.extract(from: "https://a.b/c?click_id=abcDEF12345!"))
    }

    /// The format that shipped in 0.1.0 and never worked: a custom scheme with
    /// no `//` classifies as `.probableWebSearch`, so the read gate never
    /// opened. Kept as a test so nobody reintroduces it as "the" payload.
    func testRejectsTheLegacyCustomSchemeForm() {
        XCTAssertNil(ClipboardReader.extract(from: "linksense:click_id=abcDEF12345_"))
    }
}
