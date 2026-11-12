import XCTest
@testable import LinkSense

/// Covers the idempotency-protocol invariants from §B / §E of the plan:
///   * Retries reuse the same install_idempotency_key.
///   * The key is cleared only after a 2xx.
///   * A crash between retries (modelled by rebuilding the resolver
///     against the same storage) replays the same key.
final class AttributionResolverTests: XCTestCase {

    private func makeResolver(
        network: NetworkManagerProtocol,
        storage: StorageManagerProtocol,
        fingerprint: FingerprintCollectorProtocol = StubFingerprintCollector(),
        clipboard: ClipboardReaderProtocol = StubClipboardReader(),
        enableClipboard: Bool = false
    ) -> AttributionResolver {
        return AttributionResolver(
            network: network,
            storage: storage,
            fingerprint: fingerprint,
            clipboard: clipboard,
            bundleId: "com.acme.app",
            enableClipboard: enableClipboard
        )
    }

    private func successResponse(deepLink: String? = "https://acme-42.linksense.net/signup?ref=maria") -> InstallResponse {
        return InstallResponse(
            app_install_id: "install-1",
            deep_link: deepLink,
            dynamic_link_id: "link-1",
            match_method: "play_install_referrer",
            confidence: 1.0
        )
    }

    func test_happy_path_emits_single_request_and_returns_deep_link() {
        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: false)]
        let storage = InMemoryStorage()
        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "install completes")
        resolver.reportInstall { result in
            XCTAssertEqual(result?.deepLink?.absoluteString, "https://acme-42.linksense.net/signup?ref=maria")
            XCTAssertEqual(result?.appInstallId, "install-1")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(network.sent.count, 1)
        XCTAssertNil(storage.idempotencyKey, "key should be cleared after 2xx")
        XCTAssertTrue(storage.firstLaunchDone)
    }

    func test_idempotent_replay_surfaces_flag_but_still_returns_result() {
        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: true)]
        let storage = InMemoryStorage()
        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "install completes")
        resolver.reportInstall { result in
            XCTAssertNotNil(result)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func test_network_retry_reuses_same_idempotency_key() {
        let network = MockNetworkManager()
        // First attempt fails, second attempt succeeds.
        network.scripted = [
            .failure(.network(underlying: NSError(domain: "test", code: -1))),
            .success(data: successResponse(), idempotentReplay: false),
        ]
        let storage = InMemoryStorage()
        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "install completes after retry")
        resolver.reportInstall { result in
            XCTAssertNotNil(result)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)

        XCTAssertEqual(network.sent.count, 2, "expected one retry")

        struct MinBody: Decodable {
            let install_idempotency_key: String
        }
        let first = try? JSONDecoder().decode(MinBody.self, from: network.sent[0].body ?? Data())
        let second = try? JSONDecoder().decode(MinBody.self, from: network.sent[1].body ?? Data())
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.install_idempotency_key, second?.install_idempotency_key)

        XCTAssertEqual(storage.idempotencyKeyGenerations, 1, "key should only be generated once across retries")
        XCTAssertNil(storage.idempotencyKey, "key cleared after final 2xx")
    }

    func test_crash_between_retries_preserves_idempotency_key() {
        // Simulate a crash: first resolver exhausts its retries, persists
        // the pending body, then a fresh resolver (new process) picks up
        // and confirms the same key is reused.
        let storage = InMemoryStorage()
        // Pre-seed the key as if an earlier process already generated it.
        _ = storage.installIdempotencyKey()
        let originalKey = storage.idempotencyKey
        XCTAssertNotNil(originalKey)

        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: true)]
        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "install completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        struct MinBody: Decodable {
            let install_idempotency_key: String
        }
        let sent = try? JSONDecoder().decode(MinBody.self, from: network.sent[0].body ?? Data())
        XCTAssertEqual(sent?.install_idempotency_key, originalKey)
    }

    func test_clipboard_payload_only_included_when_enabled() {
        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: false)]
        let storage = InMemoryStorage()
        let clipboard = StubClipboardReader()
        clipboard.nextClickId = "abcDEF12345_"

        let resolver = makeResolver(
            network: network,
            storage: storage,
            clipboard: clipboard,
            enableClipboard: false
        )

        let exp = expectation(description: "install completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        struct MinBody: Decodable {
            let clipboard_payload: String?
        }
        let body = try? JSONDecoder().decode(MinBody.self, from: network.sent[0].body ?? Data())
        XCTAssertNil(body?.clipboard_payload)
        XCTAssertEqual(clipboard.readCallCount, 0, "clipboard should not be read when disabled")
    }

    /// Changed in Tier 2: the reader parses a click_id out of an https:// URL
    /// and the resolver sends it bare. It used to strip the
    /// `linksense:click_id=` prefix and immediately re-add it.
    func test_clipboard_payload_included_and_formatted_when_enabled() {
        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: false)]
        let storage = InMemoryStorage()
        let clipboard = StubClipboardReader()
        clipboard.nextClickId = "abcDEF12345_"

        let resolver = makeResolver(
            network: network,
            storage: storage,
            clipboard: clipboard,
            enableClipboard: true
        )

        let exp = expectation(description: "install completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        struct MinBody: Decodable {
            let clipboard_payload: String?
        }
        let body = try? JSONDecoder().decode(MinBody.self, from: network.sent[0].body ?? Data())
        XCTAssertEqual(body?.clipboard_payload, "abcDEF12345_")
        XCTAssertEqual(clipboard.readCallCount, 1)
    }

    // MARK: - Tier 2: warm-start guard (2.1)

    func test_warm_start_does_not_post_install_again() {
        // Before this guard, /install had no first-launch check AND the
        // idempotency key was cleared on 2xx — so every launch minted a fresh
        // key and the server recorded a brand new install for the same device.
        let network = MockNetworkManager()
        let storage = InMemoryStorage()
        storage.firstLaunchDone = true

        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "warm start completes")
        var received: AttributionResolver.InstallResult?
        resolver.reportInstall { result in
            received = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(network.sent.count, 0, "warm start must not hit /install")
        XCTAssertNil(received)
        XCTAssertEqual(storage.idempotencyKeyGenerations, 0, "no key should be minted on a warm start")
    }

    func test_warm_start_still_drains_waiting_completions() {
        // A late onDeferredDeepLink registration must not hang forever just
        // because there was nothing to send.
        let storage = InMemoryStorage()
        storage.firstLaunchDone = true
        let resolver = makeResolver(network: MockNetworkManager(), storage: storage)

        let exp = expectation(description: "both completions fire")
        exp.expectedFulfillmentCount = 2
        resolver.reportInstall { _ in exp.fulfill() }
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // MARK: - Tier 2: pending-install replay (2.2)

    func test_pending_body_is_resumed_verbatim_on_cold_start() {
        // The doc comment claimed this worked; nothing in Sources/ ever read
        // the persisted body back until Tier 2.
        let storage = InMemoryStorage()
        let pending = #"{"install_idempotency_key":"resumed-key-aaaaaaaaaaaaaaaa","platform":"ios","device_id_hash":"seed-from-first-attempt","bundle_id":"test.bundle","app_version":"1.0.0","sdk_version":"0.1.0","os_version":"16.0","locale":"en_US","timezone_offset":-420,"screen_logical_w":390,"screen_logical_h":844,"pixel_ratio":3,"ua":"LinkSense/0.1.0","language":"en-US"}"#
        storage.pending = (Data(pending.utf8), Date())

        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: true)]
        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "resume completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        struct MinBody: Decodable {
            let install_idempotency_key: String
            let device_id_hash: String
        }
        let sent = try? JSONDecoder().decode(MinBody.self, from: network.sent[0].body ?? Data())
        XCTAssertEqual(sent?.install_idempotency_key, "resumed-key-aaaaaaaaaaaaaaaa")
        // The ORIGINAL fingerprint, not a fresh collect() against a device
        // that may since have changed network or locale.
        XCTAssertEqual(sent?.device_id_hash, "seed-from-first-attempt")
        XCTAssertEqual(storage.idempotencyKeyGenerations, 0, "resume must not mint a new key")
        XCTAssertNil(storage.pending, "pending body cleared after 2xx")
    }

    func test_pending_body_past_ttl_is_discarded() {
        let storage = InMemoryStorage()
        let stale = Date().addingTimeInterval(-(AttributionResolver.pendingInstallTTL + 60))
        storage.pending = (Data(#"{"install_idempotency_key":"stale"}"#.utf8), stale)

        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: false)]
        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "fresh install completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        struct MinBody: Decodable { let install_idempotency_key: String }
        let sent = try? JSONDecoder().decode(MinBody.self, from: network.sent[0].body ?? Data())
        XCTAssertNotEqual(sent?.install_idempotency_key, "stale", "a day-old fingerprint must not be resent")
    }

    func test_corrupt_pending_body_falls_back_to_fresh_compose() {
        let storage = InMemoryStorage()
        storage.pending = (Data("{not json".utf8), Date())

        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: false)]
        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "fresh install completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(network.sent.count, 1, "a corrupt body must not wedge the install")
    }

    /// A resumable body must win over the warm-start guard: the install that
    /// failed never completed, so the guard would otherwise strand it forever.
    func test_pending_body_is_resumed_even_when_first_launch_is_done() {
        let storage = InMemoryStorage()
        storage.firstLaunchDone = true
        storage.pending = (Data(#"{"install_idempotency_key":"resumed-key-aaaaaaaaaaaaaaaa","platform":"ios","device_id_hash":"s","bundle_id":"b","app_version":"1","sdk_version":"1","os_version":"16.0","locale":"en_US","timezone_offset":0,"screen_logical_w":390,"screen_logical_h":844,"pixel_ratio":3,"ua":"u","language":"en"}"#.utf8), Date())

        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: false)]
        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "resume completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(network.sent.count, 1)
    }

    // MARK: - Tier 2: retry jitter + Retry-After (2.4)

    func test_retry_after_header_overrides_the_backoff_schedule() {
        // Retrying before the bucket refills is guaranteed to fail and burns
        // quota that is shared across every device on the project.
        let delay = AttributionResolver.retryDelay(
            for: .rateLimited(retryAfterSeconds: 42),
            scheduleIndex: 0,
            jitter: { _ in 0 }
        )
        XCTAssertEqual(delay, 42, accuracy: 0.001)
    }

    func test_retry_after_is_clamped() {
        let delay = AttributionResolver.retryDelay(
            for: .rateLimited(retryAfterSeconds: 99_999),
            scheduleIndex: 0,
            jitter: { _ in 0 }
        )
        XCTAssertEqual(delay, AttributionResolver.maxRetryAfter, accuracy: 0.001)
    }

    func test_absent_retry_after_falls_back_to_the_schedule() {
        let delay = AttributionResolver.retryDelay(
            for: .rateLimited(retryAfterSeconds: nil),
            scheduleIndex: 1,
            jitter: { _ in 0 }
        )
        XCTAssertEqual(delay, NetworkManager.defaultBackoffSchedule[1], accuracy: 0.001)
    }

    func test_backoff_is_jittered_within_25_percent() {
        // Rate limiting is per-key and shared project-wide, so an outage
        // recovers into a thundering herd unless the schedules decorrelate.
        let base = NetworkManager.defaultBackoffSchedule[2]
        let error = LinkSenseError.network(underlying: NSError(domain: "t", code: 1))

        let low = AttributionResolver.retryDelay(for: error, scheduleIndex: 2, jitter: { $0.lowerBound })
        let high = AttributionResolver.retryDelay(for: error, scheduleIndex: 2, jitter: { $0.upperBound })

        XCTAssertEqual(low, base * 0.75, accuracy: 0.001)
        XCTAssertEqual(high, base * 1.25, accuracy: 0.001)

        // And the real generator stays inside that envelope.
        for _ in 0..<200 {
            let d = AttributionResolver.retryDelay(for: error, scheduleIndex: 2)
            XCTAssertGreaterThanOrEqual(d, base * 0.75)
            XCTAssertLessThanOrEqual(d, base * 1.25)
        }
    }

    func test_jittered_delay_never_goes_non_positive() {
        let error = LinkSenseError.network(underlying: NSError(domain: "t", code: 1))
        let d = AttributionResolver.retryDelay(for: error, scheduleIndex: 0, jitter: { $0.lowerBound })
        XCTAssertGreaterThan(d, 0)
    }

    // MARK: - Tier 2: consented paste path (2.6)

    func test_submit_pasted_link_extracts_click_id_and_posts_install() {
        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: false)]
        let storage = InMemoryStorage()
        let clipboard = StubClipboardReader()

        let resolver = makeResolver(network: network, storage: storage, clipboard: clipboard, enableClipboard: false)

        let exp = expectation(description: "paste resolves")
        resolver.submitPastedLink("https://acme-42.linksense.net/invite?click_id=abcDEF12345_") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        struct MinBody: Decodable { let clipboard_payload: String? }
        let body = try? JSONDecoder().decode(MinBody.self, from: network.sent[0].body ?? Data())
        XCTAssertEqual(body?.clipboard_payload, "abcDEF12345_")
        // The user's gesture is the consent — the automatic reader is bypassed
        // entirely, and enableClipboard does not gate this path.
        XCTAssertEqual(clipboard.readCallCount, 0)
    }

    func test_submit_pasted_link_ignores_a_value_with_no_click_id() {
        let network = MockNetworkManager()
        let resolver = makeResolver(network: network, storage: InMemoryStorage())

        let exp = expectation(description: "paste resolves")
        var resolved: URL?
        resolver.submitPastedLink("https://example.com/just-a-link") { url in
            resolved = url
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertNil(resolved)
        XCTAssertEqual(network.sent.count, 0, "nothing to claim — do not post")
    }

    // MARK: - Tier 3.4: deferred-match polling

    private func unmatchedResponse() -> InstallResponse {
        // The install landed, but the matcher found nothing — which can mean the
        // click fingerprint simply had not reached the server yet.
        return InstallResponse(
            app_install_id: "install-1",
            deep_link: nil,
            dynamic_link_id: nil,
            match_method: nil,
            confidence: 0
        )
    }

    private func deferredResponse(deepLink: String?) -> DeferredMatchResponse {
        return DeferredMatchResponse(
            app_install_id: "install-1",
            deep_link: deepLink,
            dynamic_link_id: deepLink == nil ? nil : "link-1",
            match_method: deepLink == nil ? nil : "fingerprint",
            confidence: deepLink == nil ? 0 : 0.91,
            ambiguous: false
        )
    }

    func test_unmatched_install_polls_deferred_match_and_recovers_the_link() {
        // The race this exists for: click fingerprints arrive fire-and-forget
        // from the edge, so an install can beat its own click row. That verdict
        // used to be permanent — one attribution_matches row per install, and
        // nothing ever revisited it.
        let network = MockNetworkManager()
        network.scripted = [
            .success(data: unmatchedResponse(), idempotentReplay: false),
            .success(data: deferredResponse(deepLink: "https://acme-42.linksense.net/late"), idempotentReplay: false),
        ]
        let resolver = makeResolver(network: network, storage: InMemoryStorage())

        let exp = expectation(description: "install completes")
        var received: URL?
        resolver.reportInstall { result in
            received = result?.deepLink
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)

        XCTAssertEqual(received?.absoluteString, "https://acme-42.linksense.net/late")
        XCTAssertEqual(network.sent.count, 2)
        XCTAssertEqual(network.sent[1].endpoint.path(), "/api/sdk/v1/deferred-match")
    }

    func test_deferred_match_body_carries_the_install_fields_and_id() {
        // app_installs persists neither the deterministic payloads nor the
        // screen/language fields, so the server cannot re-run the matcher from
        // stored state — the SDK has to resend them. bundle_id also satisfies
        // origin_allowlist, which this endpoint never used to check.
        let network = MockNetworkManager()
        network.scripted = [
            .success(data: unmatchedResponse(), idempotentReplay: false),
            .success(data: deferredResponse(deepLink: nil), idempotentReplay: false),
        ]
        let resolver = makeResolver(network: network, storage: InMemoryStorage())

        let exp = expectation(description: "install completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 15)

        struct PollBody: Decodable {
            let app_install_id: String
            let install_idempotency_key: String
            let bundle_id: String
            let platform: String
            let screen_logical_w: Int
            let language: String
        }
        let body = try? JSONDecoder().decode(PollBody.self, from: network.sent[1].body ?? Data())
        XCTAssertEqual(body?.app_install_id, "install-1")
        XCTAssertEqual(body?.bundle_id, "com.acme.app")
        XCTAssertEqual(body?.platform, "ios")
        XCTAssertEqual(body?.screen_logical_w, 390)
        XCTAssertEqual(body?.language, "en-US")
    }

    func test_matched_install_never_polls() {
        // A matched install must not pay the poll delay.
        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: false)]
        let resolver = makeResolver(network: network, storage: InMemoryStorage())

        let exp = expectation(description: "install completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(network.sent.count, 1)
        XCTAssertEqual(network.sent[0].endpoint.path(), "/api/sdk/v1/install")
    }

    func test_handler_still_fires_exactly_once_when_the_poll_finds_nothing() {
        // The poll runs BEFORE delivery precisely so this contract holds:
        // onDeferredDeepLink is documented as firing once per install, and a
        // late second callback would be a behavioural break for integrators.
        let network = MockNetworkManager()
        network.scripted = [
            .success(data: unmatchedResponse(), idempotentReplay: false),
            .success(data: deferredResponse(deepLink: nil), idempotentReplay: false),
            .success(data: deferredResponse(deepLink: nil), idempotentReplay: false),
        ]
        let resolver = makeResolver(network: network, storage: InMemoryStorage())

        var callCount = 0
        let exp = expectation(description: "install completes")
        resolver.reportInstall { result in
            callCount += 1
            XCTAssertNil(result?.deepLink)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)

        // Let any stray extra invocation land before asserting.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settle.fulfill() }
        wait(for: [settle], timeout: 5)

        XCTAssertEqual(callCount, 1)
    }

    func test_poll_stops_after_the_schedule_is_exhausted() {
        let network = MockNetworkManager()
        network.scripted = [
            .success(data: unmatchedResponse(), idempotentReplay: false),
            .success(data: deferredResponse(deepLink: nil), idempotentReplay: false),
            .success(data: deferredResponse(deepLink: nil), idempotentReplay: false),
            .success(data: deferredResponse(deepLink: nil), idempotentReplay: false),
        ]
        let resolver = makeResolver(network: network, storage: InMemoryStorage())

        let exp = expectation(description: "install completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 15)

        // 1 install + exactly as many polls as the schedule allows.
        XCTAssertEqual(network.sent.count, 1 + AttributionResolver.deferredMatchPollSchedule.count)
    }

    func test_app_install_id_is_persisted_for_later_polling() {
        // install_idempotency_key is cleared on 2xx, so this is the only
        // durable handle on the install row.
        let network = MockNetworkManager()
        network.scripted = [.success(data: successResponse(), idempotentReplay: false)]
        let storage = InMemoryStorage()
        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "install completes")
        resolver.reportInstall { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(storage.appInstallId(), "install-1")
        XCTAssertNil(storage.idempotencyKey, "key cleared on 2xx — hence the need for app_install_id")
    }

    func test_warm_path_universal_link_echoes_url_without_install_post() {
        let network = MockNetworkManager()
        let storage = InMemoryStorage()
        storage.firstLaunchDone = true // warm path

        let resolver = makeResolver(network: network, storage: storage)

        let exp = expectation(description: "warm path completes")
        resolver.handleUniversalLink(URL(string: "https://acme-42.linksense.net/invite?click_id=abcDEF12345_")!) { resolved in
            XCTAssertEqual(resolved?.absoluteString, "https://acme-42.linksense.net/invite?click_id=abcDEF12345_")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        // The only call is the /open report — the warm path must not hit /install.
        XCTAssertEqual(network.sent.map { $0.endpoint.path() }, ["/api/sdk/v1/open"])
        let body = network.lastBody(as: OpenBody.self)
        XCTAssertEqual(body?.platform, "ios")
        XCTAssertEqual(body?.url, "https://acme-42.linksense.net/invite?click_id=abcDEF12345_")
        XCTAssertEqual(body?.bundle_id, "com.acme.app")
        XCTAssertEqual(body?.sdk_version, SDKVersion.current)
    }
}
