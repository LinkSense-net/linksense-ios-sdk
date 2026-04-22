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
///   * `screenLogicalW/H` — points (matches Safari `window.screen.width`)
///   * `pixelRatio` — `UIScreen.main.scale`
///   * `locale`, `language`, `timezoneOffset`
///   * `appVersion`, `bundleId`
///   * `deviceIDHash` — SHA-256(IDFV || project salt) computed server-side
///      on the first /install response. Until then we send the raw seed.
///
/// Fields deliberately NOT collected:
///   * IDFA (never — no ATT prompt needed)
///   * Raw IDFV (we hash it server-side with a per-project salt before
///     storing; the seed we send is the identifier-for-vendor uuid)
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
        let device = UIDevice.current
        osVersion = device.systemVersion
        let screen = UIScreen.main
        screenW = Int(screen.bounds.width)
        screenH = Int(screen.bounds.height)
        pixelRatio = Double(screen.scale)
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
    /// simulator edge cases). The server salts + hashes this before
    /// storage — the seed itself never persists server-side.
    static func generateDeviceIDSeed() -> String {
        #if canImport(UIKit)
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            return idfv
        }
        #endif
        return UUID().uuidString
    }

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

    /// The OS-level UserAgent is scoped to WKWebView / Safari. For our
    /// attribution we want a stable SDK-identifiable UA the server can
    /// parse and cross-reference with the click-time UA.
    private static func syntheticUserAgent(
        bundleId: String,
        appVersion: String,
        osVersion: String,
        model: String
    ) -> String {
        return "LinkSense/\(SDKVersion.current) (\(bundleId); \(model); iOS \(osVersion); v\(appVersion))"
    }
}
