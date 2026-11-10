import Foundation

/// Public entry point for the LinkSense iOS SDK.
///
/// Lifecycle:
///   1. `LinkSense.shared.configure(...)` — once, at app launch.
///   2. `LinkSense.shared.start()` — kicks off the `/install` post on
///      first launch (idempotent on every subsequent start).
///   3. `LinkSense.shared.onDeferredDeepLink { url in ... }` — called with
///      the resolved deep link exactly once per install, on the main
///      queue. Safe to register after `start()` — the resolver buffers
///      the first result.
///   4. `LinkSense.shared.continueUserActivity(_:handler:)` — forward
///      Universal-Link activity from the app delegate.
///
/// Threading: public methods are callable from any queue. Completion
/// handlers and the deferred-deep-link handler fire on the main queue.
public final class LinkSense: @unchecked Sendable {
    public static let shared = LinkSense()

    private let queue = DispatchQueue(label: "com.linksense.sdk", qos: .utility)
    private var configuration: LinkSenseConfiguration?
    private var resolver: AttributionResolver?
    private var linkClient: LinkClient?
    private var deferredHandler: ((URL?) -> Void)?
    private var bufferedDeferredResult: URL??

    // MARK: - Internal factory (tests only)

    internal static func testing(
        network: NetworkManagerProtocol,
        storage: StorageManagerProtocol,
        fingerprint: FingerprintCollectorProtocol,
        clipboard: ClipboardReaderProtocol
    ) -> LinkSense {
        let instance = LinkSense()
        instance.configuration = LinkSenseConfiguration(
            sdkKey: "ls_sdk_00000000_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        instance.resolver = AttributionResolver(
            network: network,
            storage: storage,
            fingerprint: fingerprint,
            clipboard: clipboard,
            bundleId: "test.bundle",
            enableClipboard: true
        )
        instance.linkClient = LinkClient(network: network)
        return instance
    }

    // MARK: - Lifecycle

    /// Store configuration. Must be called exactly once before any other
    /// method. Subsequent calls are no-ops (we log a warning in `.debug`).
    public func configure(_ configuration: LinkSenseConfiguration) {
        queue.sync {
            if self.configuration != nil {
                Logger.warn("configure(_:) called more than once — subsequent call ignored")
                return
            }
            guard SdkKeyFormat.isValid(configuration.sdkKey) else {
                Logger.error("Invalid SDK key format — SDK disabled")
                return
            }
            Logger.configure(level: configuration.logLevel)
            self.configuration = configuration

            let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
            let storage = UserDefaultsStorage()
            let network = NetworkManager(
                sdkKey: configuration.sdkKey,
                sdkVersion: SDKVersion.current
            )
            let fingerprint = FingerprintCollector()
            let clipboard = ClipboardReader(storage: storage)
            self.resolver = AttributionResolver(
                network: network,
                storage: storage,
                fingerprint: fingerprint,
                clipboard: clipboard,
                bundleId: bundleId,
                enableClipboard: configuration.enableClipboard
            )
            self.linkClient = LinkClient(network: network)
        }
    }

    /// Trigger the first-launch `/install` call.
    ///
    /// Safe to call from `application(_:didFinishLaunchingWithOptions:)` and
    /// safe to call repeatedly: once an install has been acknowledged, later
    /// calls short-circuit without touching the network. A previous attempt
    /// that failed is resumed here with its original body and idempotency key.
    /// The handler still fires (with `nil`) on a warm start, so registering
    /// `onDeferredDeepLink` late never hangs.
    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let resolver = self.resolver else {
                Logger.error("start() called before configure(_:)")
                return
            }
            resolver.reportInstall { [weak self] result in
                guard let self = self else { return }
                self.queue.async {
                    let deepLink = result?.deepLink
                    if let handler = self.deferredHandler {
                        DispatchQueue.main.async { handler(deepLink) }
                    } else {
                        self.bufferedDeferredResult = deepLink
                    }
                }
            }
        }
    }

    /// Register a handler to receive the deferred deep link that matched
    /// this install. Called on the main queue. If a result was already
    /// resolved before the handler was registered, it fires on the next
    /// runloop tick.
    public func onDeferredDeepLink(_ handler: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.deferredHandler = handler
            if let buffered = self.bufferedDeferredResult {
                self.bufferedDeferredResult = nil
                DispatchQueue.main.async { handler(buffered) }
            }
        }
    }

    /// Forward a `NSUserActivity` from the app delegate — handles the
    /// Universal Link launch path. Returns `true` if the activity was
    /// consumed by the SDK. The handler fires on the main queue with
    /// the resolved deep-link URL (which may equal the webpageURL for
    /// pass-through cases).
    @discardableResult
    public func continueUserActivity(
        _ userActivity: NSUserActivity,
        handler: @escaping (URL?) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL,
              let resolver = resolver
        else {
            return false
        }
        resolver.handleUniversalLink(url) { resolved in
            DispatchQueue.main.async { handler(resolved) }
        }
        return true
    }

    /// Resolve a LinkSense link the user pasted, and claim it as this
    /// install's attribution if the install has not been attributed yet.
    ///
    /// Use this to back your own paste UI — a `PasteButton`, a
    /// `UIPasteControl`, or a "paste your invite link" text field. It is the
    /// only clipboard path on iOS 16+ that does not raise a system paste
    /// alert, because the user's own gesture supplies the consent.
    ///
    /// Values without a recognisable `click_id` resolve to `nil`; nothing is
    /// sent. The handler fires on the main queue.
    ///
    /// See also `LinkSensePasteButton`, which wraps this in a drop-in SwiftUI
    /// control.
    public func submitPastedLink(
        _ pasted: String,
        completion: @escaping (URL?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let resolver = self.resolver else {
                Logger.error("submitPastedLink(_:) called before configure(_:)")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            resolver.submitPastedLink(pasted, handler: completion)
        }
    }

    // MARK: - Link CRUD (thin passthroughs to the backend)

    public func createLink(
        options: CreateLinkOptions,
        completion: @escaping (Result<Link, LinkSenseError>) -> Void
    ) {
        withLinkClient(completion: completion) { client in
            client.create(options: options, completion: completion)
        }
    }

    public func getLink(
        id: String,
        completion: @escaping (Result<Link, LinkSenseError>) -> Void
    ) {
        withLinkClient(completion: completion) { client in
            client.get(id: id, completion: completion)
        }
    }

    public func updateLink(
        _ id: String,
        options: UpdateLinkOptions,
        completion: @escaping (Result<Link, LinkSenseError>) -> Void
    ) {
        withLinkClient(completion: completion) { client in
            client.update(id: id, options: options, completion: completion)
        }
    }

    public func deleteLink(
        _ id: String,
        completion: @escaping (Result<Void, LinkSenseError>) -> Void
    ) {
        withLinkClient(completion: completion) { client in
            client.delete(id: id, completion: completion)
        }
    }

    private func withLinkClient<T>(
        completion: @escaping (Result<T, LinkSenseError>) -> Void,
        action: (LinkClient) -> Void
    ) {
        guard let client = linkClient else {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return
        }
        action(client)
    }
}
