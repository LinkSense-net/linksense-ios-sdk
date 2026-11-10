import Foundation

/// All errors surfaced by the LinkSense public API.
///
/// Error codes mirror the server-side error codes returned by
/// `/api/sdk/v1/*` so the same mental model applies across the transport
/// boundary. `.unknown` wraps unexpected `URLError`s and decoding failures.
public enum LinkSenseError: Error, LocalizedError, Equatable {
    /// `configure(_:)` was never called, or was called with an invalid SDK key.
    case notConfigured
    /// The SDK key supplied to `configure(_:)` does not match the `ls_sdk_`
    /// format.
    case invalidSdkKey
    /// Transport-level failure (no connectivity, timeout, TLS error, etc).
    case network(underlying: Error)
    /// Server returned a 4xx / 5xx with the structured error envelope.
    case server(code: String, message: String, status: Int)
    /// Response decoded successfully but did not match the expected shape.
    case decodeFailure(message: String)
    /// The SDK key is not allowed to mutate the link being targeted (server
    /// returned 403 FORBIDDEN_CROSS_SCOPE). See §B.1 of the mobile-SDK plan.
    case forbiddenCrossScope
    /// An SDK-side create/update contained a disallowed field (server
    /// returned 400 FORBIDDEN_FIELD).
    case forbiddenField
    /// Rate-limited (429). `retryAfter` is seconds from now.
    case rateLimited(retryAfter: Int?)
    /// SDK key is missing, malformed, or unknown (401 UNAUTHORIZED / AUTH_REQUIRED).
    case unauthorized
    /// Requested resource does not exist or is not visible to this SDK key (404).
    case notFound
    /// Slug is already taken in this project (409 CUSTOM_PATH_EXISTS). Only
    /// surfaced from `createLink`.
    case customPathExists
    /// Request body failed validation (400 INVALID_INPUT). `fieldErrors` is
    /// the server's per-field detail map (field name → human-readable
    /// message); empty when the server didn't include one.
    case invalidInput(fieldErrors: [String: String])

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "LinkSense.shared.configure(_:) must be called before any other method."
        case .invalidSdkKey:
            return "SDK key format is invalid. Expected `ls_sdk_<project>_<random>`."
        case .network(let underlying):
            return "Network request failed: \(underlying.localizedDescription)"
        case .server(let code, let message, _):
            return "Server error (\(code)): \(message)"
        case .decodeFailure(let message):
            return "Failed to decode server response: \(message)"
        case .forbiddenCrossScope:
            return "This SDK key cannot modify that link (different creator or dashboard-curated)."
        case .forbiddenField:
            return "Request body contains a field not allowed for SDK-created links."
        case .rateLimited(let retryAfter):
            if let retryAfter = retryAfter {
                return "Rate limit exceeded. Retry after \(retryAfter) seconds."
            }
            return "Rate limit exceeded. Please slow down."
        case .unauthorized:
            return "SDK key is missing, malformed, or unknown."
        case .notFound:
            return "Resource not found."
        case .customPathExists:
            return "That slug is already in use for this project."
        case .invalidInput(let fieldErrors):
            if fieldErrors.isEmpty {
                return "Request body failed validation."
            }
            let detail = fieldErrors
                .map { "\($0.key): \($0.value)" }
                .sorted()
                .joined(separator: ", ")
            return "Request body failed validation: \(detail)"
        }
    }

    public static func == (lhs: LinkSenseError, rhs: LinkSenseError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured),
             (.invalidSdkKey, .invalidSdkKey),
             (.forbiddenCrossScope, .forbiddenCrossScope),
             (.forbiddenField, .forbiddenField),
             (.unauthorized, .unauthorized),
             (.notFound, .notFound),
             (.customPathExists, .customPathExists):
            return true
        case let (.server(c1, _, s1), .server(c2, _, s2)):
            return c1 == c2 && s1 == s2
        case let (.rateLimited(r1), .rateLimited(r2)):
            return r1 == r2
        case let (.decodeFailure(m1), .decodeFailure(m2)):
            return m1 == m2
        case let (.invalidInput(f1), .invalidInput(f2)):
            return f1 == f2
        case (.network, .network):
            // URLError / NSError are not Equatable — treat same-case as equal.
            return true
        default:
            return false
        }
    }
}
