import Foundation

/// Orchestrates the first-launch `/install` call: build the body from a
/// snapshot of the fingerprint and clipboard (if enabled), POST it with
/// the idempotent retry schedule, and surface the resulting deep link.
///
/// Idempotency invariants (mirror §Install idempotency contract in the plan):
///   * `install_idempotency_key` is pulled from `StorageManagerProtocol`
///     BEFORE composing the body. On first read it's generated and
///     persisted; on every retry the same key is returned.
///   * The key is cleared only after a 2xx server response.
///   * Crash / background / process death between retries re-emits the
///     same key on next attempt (the retry body is also persisted in
///     UserDefaults so queued retries survive a cold start).
final class AttributionResolver {
    struct InstallResult {
        let appInstallId: String?
        let deepLink: URL?
        let dynamicLinkId: String?
        let matchMethod: String?
        let confidence: Double
    }

    private let network: NetworkManagerProtocol
    private let storage: StorageManagerProtocol
    private let fingerprint: FingerprintCollectorProtocol
    private let clipboard: ClipboardReaderProtocol
    private let bundleId: String
    private let enableClipboard: Bool
    private let serialQueue = DispatchQueue(label: "com.linksense.sdk.attribution", qos: .utility)
    private var inFlight: Bool = false
    private var pendingCompletions: [(InstallResult?) -> Void] = []

    init(
        network: NetworkManagerProtocol,
        storage: StorageManagerProtocol,
        fingerprint: FingerprintCollectorProtocol,
        clipboard: ClipboardReaderProtocol,
        bundleId: String,
        enableClipboard: Bool
    ) {
        self.network = network
        self.storage = storage
        self.fingerprint = fingerprint
        self.clipboard = clipboard
        self.bundleId = bundleId
        self.enableClipboard = enableClipboard
    }

    /// Report a (possibly first) install. Idempotent on every retry —
    /// the server dedupes on `(project_id, install_idempotency_key)`.
    /// The completion fires exactly once per call.
    func reportInstall(completion: @escaping (InstallResult?) -> Void) {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingCompletions.append(completion)
            if self.inFlight { return }
            self.inFlight = true

            let body = self.composeInstallBody(deepLink: nil)
            self.sendWithRetry(body: body, scheduleIndex: 0) { [weak self] outcome in
                guard let self = self else { return }
                self.serialQueue.async {
                    let handlers = self.pendingCompletions
                    self.pendingCompletions.removeAll()
                    self.inFlight = false
                    DispatchQueue.main.async {
                        for handler in handlers {
                            handler(outcome)
                        }
                    }
                }
            }
        }
    }

    /// Called by `LinkSense.shared.continueUserActivity`. Treats the
    /// universal-link URL as an inline attribution hint; the server
    /// carries it through the matcher if this is also the first install.
    func handleUniversalLink(_ url: URL, handler: @escaping (URL?) -> Void) {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.storage.isFirstLaunch() {
                // Warm path — we have no `/install` to fire, just echo
                // the URL back so the caller can route in-app.
                DispatchQueue.main.async { handler(url) }
                return
            }
            let body = self.composeInstallBody(deepLink: url)
            self.sendWithRetry(body: body, scheduleIndex: 0) { outcome in
                DispatchQueue.main.async { handler(outcome?.deepLink ?? url) }
            }
        }
    }

    // MARK: - Body composition

    private func composeInstallBody(deepLink: URL?) -> InstallBody {
        let fp = fingerprint.collect()
        let clipboardPayload: String? = enableClipboard
            ? clipboard.readDeferredClickId().map { "linksense:click_id=\($0)" }
            : nil
        return InstallBody(
            install_idempotency_key: storage.installIdempotencyKey(),
            platform: "ios",
            device_id_hash: fp.deviceIDSeed, // server salts + hashes on its side
            bundle_id: bundleId,
            app_version: fp.appVersion,
            sdk_version: SDKVersion.current,
            os_version: fp.osVersion,
            locale: fp.locale,
            timezone_offset: fp.timezoneOffsetMinutes,
            screen_logical_w: fp.screenLogicalW,
            screen_logical_h: fp.screenLogicalH,
            pixel_ratio: fp.pixelRatio,
            ua: fp.userAgent,
            language: fp.language,
            play_install_referrer: nil,
            clipboard_payload: clipboardPayload,
            deep_link: deepLink?.absoluteString
        )
    }

    // MARK: - Retry driver

    private func sendWithRetry(body: InstallBody, scheduleIndex: Int, completion: @escaping (InstallResult?) -> Void) {
        network.send(endpoint: .install, body: body, extraHeaders: [:]) { [weak self] (result: Result<NetworkResponse<InstallResponse>, LinkSenseError>) in
            guard let self = self else { return }
            switch result {
            case .success(let response):
                self.storage.clearInstallIdempotencyKey()
                self.storage.clearPendingInstallBody()
                self.storage.markFirstLaunchComplete()
                let r = response.data
                completion(InstallResult(
                    appInstallId: r.app_install_id,
                    deepLink: r.deep_link.flatMap { URL(string: $0) },
                    dynamicLinkId: r.dynamic_link_id,
                    matchMethod: r.match_method,
                    confidence: r.confidence
                ))
            case .failure(let error):
                let schedule = NetworkManager.defaultBackoffSchedule
                if scheduleIndex < schedule.count && Self.isRetryable(error) {
                    let delay = schedule[scheduleIndex]
                    Logger.info("/install failed (\(error.localizedDescription)); retrying in \(delay)s")
                    self.serialQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.sendWithRetry(body: body, scheduleIndex: scheduleIndex + 1, completion: completion)
                    }
                } else {
                    Logger.error("/install gave up after \(scheduleIndex) retries: \(error.localizedDescription)")
                    // Persist body so a future cold start can resume.
                    if let data = try? JSONEncoder().encode(body) {
                        self.storage.storePendingInstallBody(data)
                    }
                    completion(nil)
                }
            }
        }
    }

    private static func isRetryable(_ error: LinkSenseError) -> Bool {
        switch error {
        case .network:
            return true
        case .server(_, _, let status):
            return (500...599).contains(status)
        case .rateLimited:
            return true
        default:
            return false
        }
    }
}

// MARK: - Wire types
// snake_case to match the server JSON shape; kept file-private so they
// never leak into the public API.

internal struct InstallBody: Encodable {
    let install_idempotency_key: String
    let platform: String
    let device_id_hash: String
    let bundle_id: String
    let app_version: String
    let sdk_version: String
    let os_version: String
    let locale: String
    let timezone_offset: Int
    let screen_logical_w: Int
    let screen_logical_h: Int
    let pixel_ratio: Double
    let ua: String
    let language: String
    let play_install_referrer: String?
    let clipboard_payload: String?
    let deep_link: String?
}

internal struct InstallResponse: Decodable {
    let app_install_id: String
    let deep_link: String?
    let dynamic_link_id: String?
    let match_method: String?
    let confidence: Double
}
