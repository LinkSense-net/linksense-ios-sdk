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
///     same key on next attempt: the body is persisted to UserDefaults on
///     give-up and `resolveInstallBody()` replays it verbatim on the next
///     cold start, within a 24h TTL.
///   * A warm start (install already acknowledged) sends nothing at all.
///     Without that guard the key — cleared on 2xx — would be reminted every
///     launch and the server would record a fresh install each time.
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
    /// How long a failed `/install` body stays resumable. Matches
    /// `StorageManager.PENDING_TTL_MILLIS` on Android. Past this the
    /// fingerprint inside it (IP-derived signals especially) is stale enough
    /// that resending it would match against the wrong click, or nothing.
    internal static let pendingInstallTTL: TimeInterval = 24 * 60 * 60

    /// Ceiling on a server-supplied `Retry-After`, so a bad header can't park
    /// the install indefinitely.
    internal static let maxRetryAfter: TimeInterval = 300

    private let serialQueue = DispatchQueue(label: "com.linksense.sdk.attribution", qos: .utility)
    private var inFlight: Bool = false
    private var pendingCompletions: [(InstallResult?) -> Void] = []
    /// The body of the install we just posted, kept so a `/deferred-match` poll
    /// can resend it. The server needs it: `app_installs` persists neither the
    /// deterministic payloads nor the screen/language fields, so a re-run from
    /// stored state alone would score a degraded fingerprint.
    private var lastInstallBody: InstallBody?

    /// Poll schedule for `/deferred-match` after an unmatched install.
    ///
    /// Deliberately short. This runs *before* the deferred-deep-link handler
    /// fires, so every second here is a second an organic install waits for its
    /// `nil`. A matched install never enters the poll at all. Two attempts over
    /// roughly five seconds covers the click-ingest race — a fingerprint that
    /// has not landed by then almost certainly never will.
    internal static let deferredMatchPollSchedule: [TimeInterval] = [1.5, 3.5]

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
    ///
    /// Three-way entry, mirroring `AttributionResolver.kt:98-116`:
    ///   1. A pending body from a previous failed attempt → resume it, so the
    ///      original fingerprint and idempotency key are re-sent rather than
    ///      recomposed against a device that may have moved network or locale.
    ///   2. Warm start (`/install` already succeeded) → skip entirely.
    ///   3. Otherwise → compose fresh.
    func reportInstall(completion: @escaping (InstallResult?) -> Void) {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingCompletions.append(completion)
            if self.inFlight { return }
            self.inFlight = true

            guard let body = self.resolveInstallBody() else {
                // Warm start — nothing to send. Drain waiters with nil so a
                // late onDeferredDeepLink registration still fires.
                self.finishInstall(with: nil)
                return
            }
            self.sendWithRetry(body: body, scheduleIndex: 0) { [weak self] outcome in
                guard let self = self else { return }
                self.serialQueue.async {
                    // The install landed but matched nothing. That can mean the
                    // click fingerprint had not reached the server yet — it
                    // arrives fire-and-forget from the edge — so give it a
                    // couple of seconds before calling this install organic.
                    //
                    // Deliberately *before* delivery rather than as a second
                    // callback: `onDeferredDeepLink` is documented on both SDKs
                    // as firing exactly once per install, and firing twice
                    // would be a behavioural break for every integrator.
                    let shouldPoll = outcome != nil && outcome?.deepLink == nil && outcome?.matchMethod == nil
                    guard shouldPoll else {
                        self.finishInstall(with: outcome)
                        return
                    }
                    self.pollDeferredMatch(attempt: 0) { [weak self] lateLink in
                        guard let self = self else { return }
                        self.serialQueue.async {
                            guard let lateLink = lateLink, let outcome = outcome else {
                                self.finishInstall(with: outcome)
                                return
                            }
                            self.finishInstall(with: InstallResult(
                                appInstallId: outcome.appInstallId,
                                deepLink: lateLink,
                                dynamicLinkId: outcome.dynamicLinkId,
                                matchMethod: outcome.matchMethod,
                                confidence: outcome.confidence
                            ))
                        }
                    }
                }
            }
        }
    }

    /// Drain everyone waiting on this install exactly once, on main.
    private func finishInstall(with outcome: InstallResult?) {
        let handlers = pendingCompletions
        pendingCompletions.removeAll()
        inFlight = false
        DispatchQueue.main.async {
            for handler in handlers {
                handler(outcome)
            }
        }
    }

    /// Called by `LinkSense.shared.continueUserActivity`. Treats the
    /// universal-link URL as an inline attribution hint; the server
    /// carries it through the matcher if this is also the first install.
    func handleUniversalLink(_ url: URL, handler: @escaping (URL?) -> Void) {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            self.reportOpen(url)
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

    /// Tell the backend a link opened the app (`POST /api/sdk/v1/open`).
    ///
    /// A Universal Link is matched on-device, so the edge never sees it; this
    /// report is the only way the open reaches analytics. Fire-and-forget: it
    /// never delays the deep-link handler, and a failure is only logged.
    // ponytail: one attempt, no retry — a lost open is one missing analytics
    // row. Route it through sendWithRetry if open counts must be exact.
    func reportOpen(_ url: URL) {
        let fp = fingerprint.collect()
        let body = OpenBody(
            platform: "ios",
            url: url.absoluteString,
            bundle_id: bundleId,
            device_id_hash: fp.deviceIDSeed,
            app_version: fp.appVersion,
            sdk_version: SDKVersion.current
        )
        network.send(endpoint: .open, body: body) { (result: Result<NetworkResponse<OpenResponse>, LinkSenseError>) in
            if case .failure(let error) = result {
                Logger.debug("open report failed: \(error)")
            }
        }
    }

    /// Resolve a link the *user* handed us — from a `PasteButton`, a
    /// `UIPasteControl`, or the host app's own paste UI.
    ///
    /// This is the only clipboard path on iOS 16+ that costs the user no
    /// system prompt, because the paste gesture *is* the consent. Unlike
    /// `reportInstall` it is not gated on first launch: the user asked for it,
    /// so honour it whenever they ask.
    func submitPastedLink(_ pasted: String, handler: @escaping (URL?) -> Void) {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            guard let clickId = ClipboardReader.extract(from: pasted) else {
                Logger.debug("submitPastedLink — no click_id in the pasted value")
                DispatchQueue.main.async { handler(nil) }
                return
            }
            guard self.storage.isFirstLaunch() else {
                // Already attributed. Nothing to claim, but the link itself is
                // still a valid destination for the caller to route to.
                Logger.debug("submitPastedLink — warm start, routing without /install")
                DispatchQueue.main.async { handler(URL(string: pasted)) }
                return
            }
            let body = self.composeInstallBody(deepLink: nil, clipboardClickId: clickId)
            self.sendWithRetry(body: body, scheduleIndex: 0) { outcome in
                DispatchQueue.main.async { handler(outcome?.deepLink) }
            }
        }
    }

    // MARK: - Deferred-match polling

    /// Poll `/deferred-match` for a match the install itself could not make.
    ///
    /// Click fingerprints reach the server fire-and-forget from the edge, so an
    /// install can genuinely arrive before its own click row exists. Before
    /// this, that verdict was permanent: the server writes one
    /// `attribution_matches` row per install and nothing ever revisited it.
    ///
    /// Calls back with the resolved deep link, or nil once the schedule is
    /// exhausted. Fires on the resolver's serial queue, not main.
    private func pollDeferredMatch(attempt: Int, completion: @escaping (URL?) -> Void) {
        guard attempt < Self.deferredMatchPollSchedule.count else {
            completion(nil)
            return
        }
        guard let body = lastInstallBody, let installId = storage.appInstallId() else {
            // Nothing to identify the install with — do not guess.
            completion(nil)
            return
        }

        let delay = Self.deferredMatchPollSchedule[attempt]
        serialQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            let pollBody = DeferredMatchBody(install: body, app_install_id: installId)
            self.network.send(endpoint: .deferredMatch, body: pollBody) { [weak self] (result: Result<NetworkResponse<DeferredMatchResponse>, LinkSenseError>) in
                guard let self = self else { return }
                switch result {
                case .success(let response):
                    if let link = response.data.deep_link.flatMap({ URL(string: $0) }) {
                        Logger.info("deferred match resolved on poll \(attempt + 1)")
                        completion(link)
                        return
                    }
                    self.serialQueue.async {
                        self.pollDeferredMatch(attempt: attempt + 1, completion: completion)
                    }
                case .failure(let error):
                    guard Self.isRetryableWhilePolling(error) else {
                        Logger.debug("deferred match poll gave up: \(error.localizedDescription)")
                        completion(nil)
                        return
                    }
                    self.serialQueue.async {
                        self.pollDeferredMatch(attempt: attempt + 1, completion: completion)
                    }
                }
            }
        }
    }

    // MARK: - Body composition

    /// Decide what (if anything) `reportInstall` should send. Returns nil on a
    /// warm start. See the doc comment on `reportInstall` for the ordering.
    private func resolveInstallBody() -> InstallBody? {
        if let pending = storage.pendingInstallBody() {
            let age = Date().timeIntervalSince(pending.storedAt)
            if age > Self.pendingInstallTTL {
                Logger.info("Discarding pending /install body — \(Int(age))s old, past TTL")
                storage.clearPendingInstallBody()
            } else if let body = try? JSONDecoder().decode(InstallBody.self, from: pending.data) {
                Logger.info("Resuming pending /install from storage")
                return body
            } else {
                Logger.warn("pending /install body could not be decoded — composing fresh")
                storage.clearPendingInstallBody()
            }
        }

        // Warm start. The key is cleared on 2xx, so a fresh compose here would
        // mint a NEW idempotency key and the server would record a second
        // install for the same device on every single launch.
        if !storage.isFirstLaunch() {
            Logger.debug("reportInstall — warm start, /install already completed; skipping")
            return nil
        }

        return composeInstallBody(deepLink: nil)
    }

    private func composeInstallBody(deepLink: URL?, clipboardClickId: String? = nil) -> InstallBody {
        let fp = fingerprint.collect()
        // The bare click_id. Older SDKs re-wrapped it as `linksense:click_id=`
        // after the reader had just stripped that prefix off; the server still
        // accepts that form for versions already in the wild.
        let clipboardPayload: String? = clipboardClickId
            ?? (enableClipboard ? clipboard.readDeferredClickId() : nil)
        return InstallBody(
            install_idempotency_key: storage.installIdempotencyKey(),
            platform: "ios",
            // Raw IDFV. The wire field name is historical: nothing hashes it
            // on either side. See PRIVACY.md.
            device_id_hash: fp.deviceIDSeed,
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
        network.send(endpoint: .install, body: body) { [weak self] (result: Result<NetworkResponse<InstallResponse>, LinkSenseError>) in
            guard let self = self else { return }
            switch result {
            case .success(let response):
                self.storage.clearInstallIdempotencyKey()
                self.storage.clearPendingInstallBody()
                self.storage.markFirstLaunchComplete()
                let r = response.data
                // The durable handle for /deferred-match: the idempotency key
                // was just cleared, so nothing else identifies this install.
                self.storage.storeAppInstallId(r.app_install_id)
                self.lastInstallBody = body
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
                    let delay = Self.retryDelay(for: error, scheduleIndex: scheduleIndex)
                    Logger.info("/install failed (\(error.localizedDescription)); retrying in \(String(format: "%.1f", delay))s")
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

    /// Backoff delay for the next attempt.
    ///
    /// Two corrections over a bare schedule lookup:
    ///   * **`Retry-After` wins.** A 429 tells us exactly when the bucket
    ///     refills; retrying earlier is guaranteed to fail and burns quota.
    ///     Clamped so a hostile or bogus header cannot park the install for
    ///     hours.
    ///   * **Jitter.** SDK rate limiting is per-key and shared across every
    ///     device on the project, so an outage recovers into a thundering herd
    ///     of clients whose fixed `[2,4,8,16,30]` schedules are all in phase.
    ///     ±25% decorrelates them.
    internal static func retryDelay(
        for error: LinkSenseError,
        scheduleIndex: Int,
        schedule: [TimeInterval] = NetworkManager.defaultBackoffSchedule,
        jitter: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> TimeInterval {
        let base = schedule[min(scheduleIndex, schedule.count - 1)]

        if case .rateLimited(let retryAfterSeconds) = error, let retryAfterSeconds = retryAfterSeconds, retryAfterSeconds > 0 {
            return min(TimeInterval(retryAfterSeconds), maxRetryAfter)
        }
        let spread = base * 0.25
        return max(0.1, base + jitter(-spread...spread))
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

    /// Retryability while polling `/deferred-match`, which is broader than for
    /// `/install` by exactly one case: a 404 there means the install row is not
    /// visible to this replica yet, which is a race we expect to lose briefly
    /// and win on the next attempt. On `/install` the same status would mean
    /// something is genuinely wrong.
    private static func isRetryableWhilePolling(_ error: LinkSenseError) -> Bool {
        if case .notFound = error {
            return true
        }
        if case .server(_, _, let status) = error, status == 404 {
            return true
        }
        return isRetryable(error)
    }
}

// MARK: - Wire types
// snake_case to match the server JSON shape; internal so they never leak into
// the public API. InstallBody is Codable, not just Encodable: a failed install
// is persisted and replayed verbatim on the next cold start, which is what
// keeps the idempotency key and the original fingerprint together.

internal struct InstallBody: Codable {
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

/// The `/deferred-match` request: the install body the server needs to re-run
/// the matcher, plus the id identifying which install to attach the result to.
internal struct DeferredMatchBody: Encodable {
    let install: InstallBody
    let app_install_id: String

    /// Flattened on the wire — the server reads one object, not a nested one.
    func encode(to encoder: Encoder) throws {
        try install.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app_install_id, forKey: .app_install_id)
    }

    private enum CodingKeys: String, CodingKey {
        case app_install_id
    }
}

/// Separate from `InstallResponse` on purpose: the plan-gated early return
/// sends `app_install_id: null`, which a non-optional field would fail to
/// decode — turning "not on the Pro plan" into a decode error.
internal struct DeferredMatchResponse: Decodable {
    let app_install_id: String?
    let deep_link: String?
    let dynamic_link_id: String?
    let match_method: String?
    let confidence: Double
    let ambiguous: Bool
}

/// `POST /api/sdk/v1/open` — `openBodySchema` in `src/app/api/sdk/v1/open/route.ts`.
internal struct OpenBody: Codable, Equatable {
    let platform: String
    let url: String
    let bundle_id: String
    let device_id_hash: String
    let app_version: String
    let sdk_version: String
}

/// The response body is not used; an empty struct decodes any `data` object.
internal struct OpenResponse: Decodable {}

internal struct InstallResponse: Decodable {
    let app_install_id: String
    let deep_link: String?
    let dynamic_link_id: String?
    let match_method: String?
    let confidence: Double
}
