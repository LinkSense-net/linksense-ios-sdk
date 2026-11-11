import Foundation

/// SDK persistence. Scoped to a named UserDefaults suite so neither the
/// host app nor other SDKs can collide with our keys.
///
/// Keys stored:
///   * `first_launch_done` (Bool) — flipped after the first successful
///     `/install` response; the warm-start guard that stops `/install`
///     from being re-sent on every cold start.
///   * `install_idempotency_key` (String) — 32-char URL-safe random,
///     generated once and reused on every retry until `/install` returns
///     2xx. Guarantees that a retried install never creates a second row.
///     See §E step 0 of the mobile-SDK plan.
///   * `device_id` (String) — stable per-app-install device token, generated
///     once and cached so it survives relaunches. No hashing is applied,
///     here or server-side. Currently unused by production code: the install
///     body seeds `device_id_hash` straight from
///     `FingerprintCollector.generateDeviceIDSeed()` instead.
///   * `pending_install_body` (Data) — the last retrying `/install`
///     request body. 24-hour retention; cleared on 2xx success.
///   * `app_install_id` (String) — the server's id for this install, kept so
///     `/deferred-match` can be polled afterwards. It has to be persisted
///     because `install_idempotency_key` is cleared on the 2xx that produces
///     it, leaving no other durable handle on the install row.
protocol StorageManagerProtocol: AnyObject {
    func isFirstLaunch() -> Bool
    func markFirstLaunchComplete()

    func deviceID() -> String

    func installIdempotencyKey() -> String
    func clearInstallIdempotencyKey()

    func pendingInstallBody() -> (data: Data, storedAt: Date)?
    func storePendingInstallBody(_ data: Data)
    func clearPendingInstallBody()

    func appInstallId() -> String?
    func storeAppInstallId(_ id: String)

    func firstLaunchClipboardRead() -> Bool
    func markFirstLaunchClipboardRead()
}

final class UserDefaultsStorage: StorageManagerProtocol {
    private static let suiteName = "net.linksense.sdk.state"
    private let defaults: UserDefaults

    private enum Key {
        static let firstLaunchDone = "first_launch_done"
        static let installIdempotencyKey = "install_idempotency_key"
        static let deviceId = "device_id"
        static let pendingInstall = "pending_install_body"
        static let pendingInstallAt = "pending_install_at"
        static let appInstallId = "app_install_id"
        static let clipboardReadDone = "clipboard_read_done"
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    // MARK: - First-launch guard

    func isFirstLaunch() -> Bool {
        return !defaults.bool(forKey: Key.firstLaunchDone)
    }

    func markFirstLaunchComplete() {
        defaults.set(true, forKey: Key.firstLaunchDone)
    }

    // MARK: - Device ID (cached; server never sees raw)

    func deviceID() -> String {
        if let existing = defaults.string(forKey: Key.deviceId) {
            return existing
        }
        let fresh = FingerprintCollector.generateDeviceIDSeed()
        defaults.set(fresh, forKey: Key.deviceId)
        return fresh
    }

    // MARK: - Install idempotency key

    func installIdempotencyKey() -> String {
        if let existing = defaults.string(forKey: Key.installIdempotencyKey) {
            return existing
        }
        let fresh = Self.generateIdempotencyKey()
        defaults.set(fresh, forKey: Key.installIdempotencyKey)
        return fresh
    }

    func clearInstallIdempotencyKey() {
        defaults.removeObject(forKey: Key.installIdempotencyKey)
    }

    // MARK: - Pending install (retry queue)

    func pendingInstallBody() -> (data: Data, storedAt: Date)? {
        guard let data = defaults.data(forKey: Key.pendingInstall),
              let timestamp = defaults.object(forKey: Key.pendingInstallAt) as? Date
        else {
            return nil
        }
        return (data, timestamp)
    }

    func storePendingInstallBody(_ data: Data) {
        defaults.set(data, forKey: Key.pendingInstall)
        defaults.set(Date(), forKey: Key.pendingInstallAt)
    }

    func clearPendingInstallBody() {
        defaults.removeObject(forKey: Key.pendingInstall)
        defaults.removeObject(forKey: Key.pendingInstallAt)
    }

    // MARK: - App install id (handle for /deferred-match polling)

    func appInstallId() -> String? {
        return defaults.string(forKey: Key.appInstallId)
    }

    func storeAppInstallId(_ id: String) {
        defaults.set(id, forKey: Key.appInstallId)
    }

    // MARK: - Clipboard read-once guard

    func firstLaunchClipboardRead() -> Bool {
        return defaults.bool(forKey: Key.clipboardReadDone)
    }

    func markFirstLaunchClipboardRead() {
        defaults.set(true, forKey: Key.clipboardReadDone)
    }

    // MARK: - Helpers

    /// 32-char URL-safe random, ≈190 bits of entropy. Matches the contract
    /// documented in §B of the plan (`install_idempotency_key`).
    private static func generateIdempotencyKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24) // 24 bytes → 32 base64url chars
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Extremely unlikely — fall back to UUID hex so we don't crash.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// URL-safe, unpadded base64 — maps to the server's `[A-Za-z0-9_-]`
    /// click_id / idempotency alphabet.
    func base64URLEncodedString() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
