import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Clipboard-assisted deferred deep linking.
///
/// **Activation rules**:
///   * Only reads the pasteboard when the integrator opts in
///     (`enableClipboard = true` at config time).
///   * iOS 16+: uses `detectPatterns(for: [.probableWebURL])` to avoid
///     triggering a "LinkSense pasted from…" toast when there's no URL
///     content on the clipboard.
///   * iOS 14–15: `detectPatterns` is unavailable, so we fall back to a
///     single first-launch read guarded by `StorageManagerProtocol`.
///     The toast is unavoidable on those OS versions — that's the
///     tradeoff the integrator opted into.
///
/// **Payload format**: only accept `linksense:click_id=<12 char base64url>`.
/// Everything else is rejected silently — this prevents the SDK from
/// treating a user's legitimate clipboard content as attribution bait.
protocol ClipboardReaderProtocol {
    /// Returns the extracted `click_id` if the clipboard has a valid
    /// payload, nil otherwise. Returns nil when `enableClipboard` is
    /// false or when we've already performed the first-launch read.
    func readDeferredClickId() -> String?
}

final class ClipboardReader: ClipboardReaderProtocol {
    private static let payloadPrefix = "linksense:click_id="
    private let storage: StorageManagerProtocol

    init(storage: StorageManagerProtocol) {
        self.storage = storage
    }

    func readDeferredClickId() -> String? {
        #if canImport(UIKit)
        if #available(iOS 16.0, *) {
            let pasteboard = UIPasteboard.general
            // `detectPatterns(for:)` has no synchronous variant; use the
            // completion-handler form and block the attribution serial
            // queue (not main) while waiting. 2s cap so a slow pasteboard
            // service can't stall `/install` indefinitely.
            var matched = false
            let semaphore = DispatchSemaphore(value: 0)
            pasteboard.detectPatterns(for: [.probableWebURL]) { result in
                if case .success(let patterns) = result {
                    matched = patterns.contains(.probableWebURL)
                }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 2) == .success, matched else {
                return nil
            }
            return extract(from: pasteboard.string)
        } else {
            if storage.firstLaunchClipboardRead() {
                return nil
            }
            storage.markFirstLaunchClipboardRead()
            return extract(from: UIPasteboard.general.string)
        }
        #else
        return nil
        #endif
    }

    private func extract(from raw: String?) -> String? {
        guard let raw = raw, raw.hasPrefix(Self.payloadPrefix) else { return nil }
        let clickId = String(raw.dropFirst(Self.payloadPrefix.count))
        guard isValidClickId(clickId) else { return nil }
        return clickId
    }

    private func isValidClickId(_ id: String) -> Bool {
        guard id.count == 12 else { return false }
        for ch in id {
            switch ch {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-":
                continue
            default:
                return false
            }
        }
        return true
    }
}
