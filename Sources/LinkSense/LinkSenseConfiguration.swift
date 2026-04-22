import Foundation

/// Log verbosity. Off by default; turn on only during integration or when
/// debugging a specific issue — production builds should ship with `.off`.
public enum LogLevel: Int, Sendable {
    case off = 0
    case error = 1
    case info = 2
    case debug = 3
}

/// Static configuration for the LinkSense SDK. Immutable after
/// `configure(_:)` — build a fresh instance if something must change.
public struct LinkSenseConfiguration: Sendable {
    /// Publishable SDK key in the format `ls_sdk_<project>_<random>`. Ships
    /// inside your app binary — treat it as extractable.
    public let sdkKey: String

    /// Optional base URL override. Defaults to `https://linksense.net`. Set
    /// only for self-hosted deployments or internal staging.
    public let baseURL: URL

    /// Opt-in: read the pasteboard on first launch to recover a deferred
    /// deep link. Default **false**. iOS 14–15 show a user-visible paste
    /// notification even when the clipboard is empty — leave off unless
    /// your UX already explains why.
    public let enableClipboard: Bool

    /// Log verbosity. Default `.off`.
    public let logLevel: LogLevel

    public init(
        sdkKey: String,
        baseURL: URL? = nil,
        enableClipboard: Bool = false,
        logLevel: LogLevel = .off
    ) {
        self.sdkKey = sdkKey
        self.baseURL = baseURL ?? URL(string: "https://linksense.net")!
        self.enableClipboard = enableClipboard
        self.logLevel = logLevel
    }
}
