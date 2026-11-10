import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Deliberately minimal fingerprint surface.
///
/// Fields collected:
///   * `platform` = `"ios"`
///   * `model` — `UIDevice.current.modelIdentifier` (e.g. `"iPhone15,3"`)
///   * `osVersion` — system version
///   * `screenLogicalW/H` — points, portrait-normalised to match Safari's
///      portrait-fixed `window.screen.width/height`
///   * `pixelRatio` — `UIScreen.main.scale`
///   * `locale`, `language`, `timezoneOffset`
///   * `appVersion`, `bundleId`
///   * `deviceIDSeed` — the raw IDFV, sent as the `device_id_hash` wire field.
///      The field name is historical and misleading: **no hashing happens, on
///      either side.** The server stores what we send here verbatim. See
///      PRIVACY.md; correcting the column name is tracked separately.
///
/// Fields deliberately NOT collected:
///   * IDFA (never — no ATT prompt needed)
///   * MAC address / battery level / storage / RAM (Tapp collects these;
///     we deliberately don't — these reward high-accuracy fingerprinting,
///     a posture we deliberately avoid)
protocol FingerprintCollectorProtocol {
    func collect() -> DeviceFingerprint
}

struct DeviceFingerprint {
    let platform: String
    let model: String
    let osVersion: String
    let appVersion: String
    let bundleId: String
    let locale: String
    let language: String
    let timezoneOffsetMinutes: Int
    let screenLogicalW: Int
    let screenLogicalH: Int
    let pixelRatio: Double
    let deviceIDSeed: String
    let userAgent: String
}

final class FingerprintCollector: FingerprintCollectorProtocol {
    func collect() -> DeviceFingerprint {
        let bundleDict = Bundle.main.infoDictionary ?? [:]
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let appVersion = (bundleDict["CFBundleShortVersionString"] as? String) ?? "unknown"
        let osVersion: String
        let screenW: Int
        let screenH: Int
        let pixelRatio: Double
        let model: String

        #if canImport(UIKit)
        osVersion = Self.onMain { UIDevice.current.systemVersion }
        let metrics = Self.onMain { Self.screenMetrics() }
        // Portrait-normalised. `bounds` follows the current orientation, but
        // Safari's `window.screen.width/height` is portrait-fixed, and the
        // server compares these by exact equality — so an app launched in
        // landscape would send transposed dimensions and lose the match.
        screenW = Int(min(metrics.width, metrics.height))
        screenH = Int(max(metrics.width, metrics.height))
        pixelRatio = Double(metrics.scale)
        model = Self.deviceModelIdentifier() ?? "unknown"
        #else
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        screenW = 0
        screenH = 0
        pixelRatio = 1.0
        model = "unknown"
        #endif

        let localeID = Locale.current.identifier
        let language = Locale.preferredLanguages.first ?? "en"
        let timezoneOffsetMinutes = TimeZone.current.secondsFromGMT() / 60
        let seed = Self.generateDeviceIDSeed()
        let userAgent = Self.syntheticUserAgent(
            bundleId: bundleId,
            appVersion: appVersion,
            osVersion: osVersion,
            model: model
        )

        return DeviceFingerprint(
            platform: "ios",
            model: model,
            osVersion: osVersion,
            appVersion: appVersion,
            bundleId: bundleId,
            locale: localeID,
            language: language,
            timezoneOffsetMinutes: timezoneOffsetMinutes,
            screenLogicalW: screenW,
            screenLogicalH: screenH,
            pixelRatio: pixelRatio,
            deviceIDSeed: seed,
            userAgent: userAgent
        )
    }

    /// Seed for the device ID. Prefers IDFV (stable per-vendor per-install);
    /// falls back to a fresh UUID when IDFV is unavailable (e.g. iOS
    /// simulator edge cases). Sent as `device_id_hash` and **stored verbatim**
    /// — despite the wire field's name, neither side hashes it. See PRIVACY.md.
    static func generateDeviceIDSeed() -> String {
        #if canImport(UIKit)
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            return idfv
        }
        #endif
        return UUID().uuidString
    }

    #if canImport(UIKit)
    /// Run a UIKit read on the main thread. `collect()` is called from the
    /// attribution serial queue, and `UIScreen` / `UIDevice` are main-thread
    /// APIs — the main-thread checker flags them, and under Stage Manager the
    /// values can be read mid-transition. Safe against deadlock because the
    /// main queue never blocks waiting on the attribution queue.
    private static func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    /// Screen geometry for the scene the app is actually in.
    ///
    /// `UIScreen.main` is deprecated from iOS 16 and wrong under multi-scene:
    /// on iPad with Stage Manager or Split View it reports the physical
    /// display, not the window the app occupies. We want the device's screen
    /// (that is what Safari's `window.screen` reports at click time), so we
    /// resolve it through the active scene and only fall back to `.main` when
    /// no scene is connected — which is the case during very early launch.
    private static func screenMetrics() -> (width: CGFloat, height: CGFloat, scale: CGFloat) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        if let screen = scene?.screen {
            return (screen.bounds.width, screen.bounds.height, screen.scale)
        }
        let fallback = UIScreen.main
        return (fallback.bounds.width, fallback.bounds.height, fallback.scale)
    }
    #endif

    /// Raw device model identifier via `uname`. `UIDevice.current.model`
    /// returns the marketing string ("iPhone") — we need the precise
    /// code ("iPhone15,3") for fingerprint scoring.
    private static func deviceModelIdentifier() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cStr in
                String(validatingUTF8: cStr)
            }
        }
    }

    /// A stable, SDK-identifiable UA, persisted server-side as
    /// `user_agent_full` for diagnostics.
    ///
    /// It is **not** an attribution signal and cannot become one: it shares no
    /// tokens with the real Safari UA seen at click time, so parsing it yields
    /// either a value we already send as a clean field (`os_version`) or
    /// nothing at all (browser, device model). The server used to score the
    /// parse of this string; it no longer does. Do not add fields here
    /// expecting them to be matched — add them to `InstallBody` instead.
    private static func syntheticUserAgent(
        bundleId: String,
        appVersion: String,
        osVersion: String,
        model: String
    ) -> String {
        return "LinkSense/\(SDKVersion.current) (\(bundleId); \(model); iOS \(osVersion); v\(appVersion))"
    }
}
