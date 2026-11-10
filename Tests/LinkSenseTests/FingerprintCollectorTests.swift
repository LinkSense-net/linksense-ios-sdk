import XCTest
@testable import LinkSense

/// Exercises the real `FingerprintCollector`, not `StubFingerprintCollector` —
/// the stub hardcodes its values, so it cannot catch a regression here.
final class FingerprintCollectorTests: XCTestCase {

    /// The server compares screen dimensions by exact equality against a click
    /// row whose values came from Safari's `window.screen`, which is
    /// portrait-fixed. `UIScreen.bounds` is not: an app launched in landscape
    /// reports them transposed. Both sides sort to min/max so the branch — the
    /// heaviest non-IP signal at 0.20 — survives the orientation.
    func testScreenDimensionsArePortraitNormalised() {
        let fp = FingerprintCollector().collect()

        #if canImport(UIKit)
        XCTAssertLessThanOrEqual(
            fp.screenLogicalW, fp.screenLogicalH,
            "width must be the short edge regardless of launch orientation"
        )
        XCTAssertGreaterThan(fp.screenLogicalW, 0)
        XCTAssertGreaterThan(fp.pixelRatio, 0)
        #else
        // Non-UIKit build (swift test on macOS): the collector reports zeros.
        XCTAssertEqual(fp.screenLogicalW, 0)
        XCTAssertEqual(fp.screenLogicalH, 0)
        #endif
    }

    /// `|Δ| ≤ 60` on the server compares this against `-getTimezoneOffset()`
    /// from the click beacon. If this ever flips sign, every timezone except
    /// UTC silently stops matching.
    func testTimezoneOffsetUsesPosixSign() {
        let fp = FingerprintCollector().collect()

        XCTAssertEqual(fp.timezoneOffsetMinutes, TimeZone.current.secondsFromGMT() / 60)
        XCTAssertGreaterThanOrEqual(fp.timezoneOffsetMinutes, -720)
        XCTAssertLessThanOrEqual(fp.timezoneOffsetMinutes, 840)
    }

    /// `os_version` is now scored directly by the matcher (the synthetic UA is
    /// no longer parsed), so it has to be a bare version string.
    func testOsVersionIsABareVersionString() {
        let fp = FingerprintCollector().collect()

        XCTAssertFalse(fp.osVersion.isEmpty)
        #if canImport(UIKit)
        XCTAssertEqual(fp.osVersion, UIDevice.current.systemVersion)
        XCTAssertNotNil(Int(fp.osVersion.split(separator: ".").first.map(String.init) ?? ""))
        #endif
    }
}
