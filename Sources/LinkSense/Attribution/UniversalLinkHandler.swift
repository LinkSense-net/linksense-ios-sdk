import Foundation

/// Utility helpers for parsing inbound Universal Link URLs.
///
/// The active `continueUserActivity` path goes through
/// `AttributionResolver.handleUniversalLink` — this file is a small
/// helper namespace with the bits that are pure and easy to unit-test.
enum UniversalLinkHandler {
    /// Extract `click_id` from a `?click_id=<12>` query parameter, if
    /// present. Mirrors the server-side regex in `matcher.ts`.
    static func extractClickId(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        for item in queryItems where item.name == "click_id" {
            if let value = item.value, isValidClickId(value) {
                return value
            }
        }
        return nil
    }

    /// Validates a `click_id` against the same shape the server's
    /// `matcher.ts` regex accepts (12 chars, base64url alphabet).
    /// Internal so `ClipboardReader` can share the validator.
    internal static func isValidClickId(_ id: String) -> Bool {
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
