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

    /// Opt-in: read the pasteboard on first launch to recover a deferred
    /// deep link. Default **false**. On iOS 16+ the pasteboard read itself
    /// raises a system paste prompt — pattern detection is free, the read
    /// that follows it is not. Leave off unless your UX already explains
    /// why, or drive the paste from a user gesture instead via
    /// `LinkSensePasteButton` / `submitPastedLink(_:completion:)`.
    public let enableClipboard: Bool

    /// Log verbosity. Default `.off`.
    public let logLevel: LogLevel

    public init(
        sdkKey: String,
        enableClipboard: Bool = false,
        logLevel: LogLevel = .off
    ) {
        self.sdkKey = sdkKey
        self.enableClipboard = enableClipboard
        self.logLevel = logLevel
    }
}
