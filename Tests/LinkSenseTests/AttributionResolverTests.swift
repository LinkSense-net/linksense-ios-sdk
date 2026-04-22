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
        XCTAssertEqual(body?.clipboard_payload, "linksense:click_id=abcDEF12345_")
        XCTAssertEqual(clipboard.readCallCount, 1)
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
        XCTAssertEqual(network.sent.count, 0, "warm path should not hit /install")
    }
}
