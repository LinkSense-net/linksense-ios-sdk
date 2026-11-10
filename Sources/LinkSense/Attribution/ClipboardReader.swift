import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Clipboard-assisted deferred deep linking.
///
/// **This path cannot be silent, and that is not a bug we can fix.** Apple's
/// `UIPasteControl` documentation: *"In iOS 16 and later, programmatic pasting
/// raises a user alert that prompts the user for approval before the app gains
/// access to pasteboard contents."* `detectPatterns` grants no access so it
/// never notifies, but the `pasteboard.string` read immediately after it does.
/// No payload format changes that. The only prompt-free path is a user-driven
/// `PasteButton` — see `LinkSensePasteButton` and
/// `LinkSense.shared.submitPastedLink(_:)`.
///
/// Detection therefore has exactly one job here: decide whether prompting is
/// worth it at all.
///
/// **Activation rules**:
///   * Only reads when the integrator opts in (`enableClipboard = true`).
///   * Only on the first launch — `firstLaunchClipboardRead()` gates *every*
///     path, so the user sees at most one prompt per install.
///   * Only when the pasteboard already looks like a web URL, so we never
///     prompt to inspect someone's copied password.
///
/// **Payload format**: an `https://` link carrying `?click_id=<12 base64url>`.
/// Verified on iOS 18.6 and 26.5 — see `PasteboardClassifierTests`. The
/// previous `linksense:click_id=` form classified as `.probableWebSearch`, so
/// the gate never opened and this mechanism could not fire at all.
protocol ClipboardReaderProtocol {
    /// Returns the extracted `click_id` if the clipboard holds a valid
    /// payload, nil otherwise. Returns nil when `enableClipboard` is false or
    /// when the one first-launch read has already happened.
    func readDeferredClickId() -> String?
}

final class ClipboardReader: ClipboardReaderProtocol {
    private let storage: StorageManagerProtocol

    /// Cap on the detect call. The classifier runs out-of-process in the
    /// `pasted` daemon, so a wedged daemon must not stall `/install`.
    private static let detectTimeout: TimeInterval = 2

    init(storage: StorageManagerProtocol) {
        self.storage = storage
    }

    func readDeferredClickId() -> String? {
        #if canImport(UIKit)
        // One read per install, on every path. Checked before detection so a
        // second launch does not even touch the pasteboard service.
        guard !storage.firstLaunchClipboardRead() else { return nil }

        guard probablyHoldsWebURL() else {
            // Nothing URL-shaped on the pasteboard: not worth a prompt, and
            // deliberately NOT marked as read — we consumed no user attention,
            // so a later launch may still find a payload.
            return nil
        }

        storage.markFirstLaunchClipboardRead()
        // The prompt happens here, not above.
        return Self.extract(from: UIPasteboard.general.string)
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    /// Free, non-prompting check. Bridges the async API to this synchronous
    /// call — `readDeferredClickId` runs on the attribution serial queue, and
    /// blocking it is fine; blocking main would not be.
    private func probablyHoldsWebURL() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var matched = false
        Task {
            defer { semaphore.signal() }
            let found = try? await UIPasteboard.general.detectedPatterns(
                for: [\.probableWebURL]
            )
            matched = found?.contains(\UIPasteboard.DetectedValues.probableWebURL) ?? false
        }
        guard semaphore.wait(timeout: .now() + Self.detectTimeout) == .success else {
            Logger.warn("pasteboard detection timed out — skipping clipboard attribution")
            return false
        }
        return matched
    }
    #endif

    /// Pull a `click_id` out of a pasted string.
    ///
    /// Reuses `UniversalLinkHandler.extractClickId(from:)` — the payload is a
    /// real URL now, so the universal-link parser is exactly the right tool and
    /// there is no second format to keep in sync.
    internal static func extract(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw)
        else {
            return nil
        }
        return UniversalLinkHandler.extractClickId(from: url)
    }
}
