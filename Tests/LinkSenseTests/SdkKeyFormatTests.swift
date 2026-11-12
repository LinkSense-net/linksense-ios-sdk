import XCTest
@testable import LinkSense

/// Mirrors the server-side `src/tests/sdk/unit/sdk-key-utils.test.ts`
/// format tests. If the client and server disagree on what "valid"
/// means, `configure(_:)` would accept a key the server will 401 —
/// surface that mismatch at build time here instead.
final class SdkKeyFormatTests: XCTestCase {
    func test_accepts_canonical_key() {
        let key = "ls_sdk_12345678_" + String(repeating: "a", count: 32)
        XCTAssertTrue(SdkKeyFormat.isValid(key))
    }

    func test_rejects_empty_string() {
        XCTAssertFalse(SdkKeyFormat.isValid(""))
    }

    func test_rejects_wrong_prefix() {
        let key = "ls_live_12345678_" + String(repeating: "a", count: 32)
        XCTAssertFalse(SdkKeyFormat.isValid(key))
    }

    func test_rejects_too_short() {
        let key = "ls_sdk_12345678_" + String(repeating: "a", count: 31)
        XCTAssertFalse(SdkKeyFormat.isValid(key))
    }

    func test_rejects_too_long() {
        let key = "ls_sdk_12345678_" + String(repeating: "a", count: 33)
        XCTAssertFalse(SdkKeyFormat.isValid(key))
    }

    func test_rejects_missing_separator() {
        let key = "ls_sdk_12345678x" + String(repeating: "a", count: 32)
        XCTAssertFalse(SdkKeyFormat.isValid(key))
    }

    func test_rejects_uppercase_hex() {
        let key = "ls_sdk_12345678_" + String(repeating: "A", count: 32)
        XCTAssertFalse(SdkKeyFormat.isValid(key))
    }

    func test_rejects_non_hex_in_project_segment() {
        let key = "ls_sdk_1234567g_" + String(repeating: "a", count: 32)
        XCTAssertFalse(SdkKeyFormat.isValid(key))
    }

    func test_configure_throws_invalidSdkKey_for_malformed_key() {
        let sdk = LinkSense()
        XCTAssertThrowsError(try sdk.configure(LinkSenseConfiguration(sdkKey: "not-a-key"))) { error in
            XCTAssertEqual(error as? LinkSenseError, .invalidSdkKey)
        }
    }

    func test_configure_accepts_well_formed_key() {
        let sdk = LinkSense()
        XCTAssertNoThrow(try sdk.configure(LinkSenseConfiguration(
            sdkKey: "ls_sdk_12345678_" + String(repeating: "a", count: 32)
        )))
    }
}
