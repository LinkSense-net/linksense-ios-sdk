import XCTest
@testable import LinkSense

/// The storage layer holds all the invariants the idempotency protocol
/// depends on — cover each one explicitly here. Uses an in-memory
/// `UserDefaults` per test to avoid cross-test contamination.
final class UserDefaultsStorageTests: XCTestCase {

    private func freshStorage() -> UserDefaultsStorage {
        let suite = "test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UserDefaultsStorage(defaults: defaults)
    }

    func test_isFirstLaunch_true_until_markFirstLaunchComplete() {
        let storage = freshStorage()
        XCTAssertTrue(storage.isFirstLaunch())
        storage.markFirstLaunchComplete()
        XCTAssertFalse(storage.isFirstLaunch())
    }

    func test_installIdempotencyKey_is_stable_across_reads() {
        let storage = freshStorage()
        let first = storage.installIdempotencyKey()
        let second = storage.installIdempotencyKey()
        XCTAssertEqual(first, second)
    }

    func test_installIdempotencyKey_regenerates_after_clear() {
        let storage = freshStorage()
        let first = storage.installIdempotencyKey()
        storage.clearInstallIdempotencyKey()
        let second = storage.installIdempotencyKey()
        XCTAssertNotEqual(first, second)
    }

    func test_installIdempotencyKey_is_32_char_url_safe() {
        let storage = freshStorage()
        let key = storage.installIdempotencyKey()
        XCTAssertEqual(key.count, 32)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        XCTAssertTrue(key.allSatisfy { allowed.contains($0) })
    }

    func test_deviceID_is_stable_across_reads() {
        let storage = freshStorage()
        XCTAssertEqual(storage.deviceID(), storage.deviceID())
    }

    func test_pending_install_body_roundtrips() {
        let storage = freshStorage()
        XCTAssertNil(storage.pendingInstallBody())
        let bytes = Data([0x01, 0x02, 0x03])
        storage.storePendingInstallBody(bytes)
        XCTAssertEqual(storage.pendingInstallBody()?.data, bytes)
        storage.clearPendingInstallBody()
        XCTAssertNil(storage.pendingInstallBody())
    }

    func test_clipboard_read_once_guard() {
        let storage = freshStorage()
        XCTAssertFalse(storage.firstLaunchClipboardRead())
        storage.markFirstLaunchClipboardRead()
        XCTAssertTrue(storage.firstLaunchClipboardRead())
    }
}
