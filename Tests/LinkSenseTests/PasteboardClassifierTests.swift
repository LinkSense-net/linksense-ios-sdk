#if canImport(UIKit)
import XCTest
import UIKit

/// Pins the behaviour of Apple's pasteboard classifier, which our clipboard
/// deferred-deep-link payload format depends on entirely.
///
/// `detectPatterns` runs out-of-process in the `pasted` daemon and answers
/// Safari's omnibox question — navigate, or search? We gate the clipboard read
/// on `.probableWebURL`, so if Apple ever reclassifies our payload the gate
/// stops opening and clipboard attribution silently dies. Nothing else in the
/// suite would notice.
///
/// Verified identical on iOS 18.6 and 26.5 (2026-08-26).
///
/// **This does not run under `swift test`** — it needs a simulator:
/// ```
/// xcodebuild test -scheme LinkSense \
///   -destination 'platform=iOS Simulator,name=iPhone 16' \
///   -only-testing:LinkSenseTests/PasteboardClassifierTests
/// ```
/// Detection grants no content access, so none of this prompts the user.
@available(iOS 15.0, *)
final class PasteboardClassifierTests: XCTestCase {

    private func classify(_ value: String) async throws -> (url: Bool, search: Bool) {
        UIPasteboard.general.string = value
        let found = try await UIPasteboard.general.detectedPatterns(
            for: [\.probableWebURL, \.probableWebSearch]
        )
        return (
            found.contains(\UIPasteboard.DetectedValues.probableWebURL),
            found.contains(\UIPasteboard.DetectedValues.probableWebSearch)
        )
    }

    /// The payload we actually write. If this regresses, clipboard attribution
    /// is dead and the fingerprint path is the only iOS DDL left.
    func testHttpsPayloadClassifiesAsWebURL() async throws {
        let result = try await classify("https://lnk.sn/abc123?click_id=Ab3dEf9hJ2kL")
        XCTAssertTrue(result.url, "the https:// click payload must pass the .probableWebURL gate")
    }

    /// The payload we used to write, and why it never worked: a custom scheme
    /// with no `//` is non-hierarchical, so the classifier checks it against a
    /// scheme whitelist that `linksense` is not on.
    func testLegacyCustomSchemePayloadIsNotAWebURL() async throws {
        let result = try await classify("linksense:click_id=Ab3dEf9hJ2kL")
        XCTAssertFalse(result.url, "regression: the legacy payload is not supposed to pass the gate")
        XCTAssertTrue(result.search)
    }

    /// Documents the boundary — the whitelist only governs non-hierarchical
    /// URLs, so a custom scheme *with* `//` passes. We do not rely on this
    /// (it is undocumented), but it explains why the legacy payload's problem
    /// was the missing slashes, not the scheme.
    func testCustomSchemeWithAuthorityIsAWebURL() async throws {
        let result = try await classify("linksense://click/Ab3dEf9hJ2kL")
        XCTAssertTrue(result.url)
    }

    func testNonSchemeStringIsNotAWebURL() async throws {
        let result = try await classify("notascheme:foo=bar")
        XCTAssertFalse(result.url)
    }
}
#endif
