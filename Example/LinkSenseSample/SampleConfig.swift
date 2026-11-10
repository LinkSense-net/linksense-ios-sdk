import Foundation

struct SampleConfig {
    let sdkKey: String
    let appLinkHost: String

    static let placeholderKey = "ls_sdk_TODO_SET_LINKSENSE_SDK_KEY_in_Secrets_xcconfig"

    var isUnconfigured: Bool { sdkKey.hasPrefix("ls_sdk_TODO") }

    var maskedSdkKey: String {
        sdkKey.count > 6 ? "…" + sdkKey.suffix(6) : sdkKey
    }

    static func load() -> SampleConfig {
        let info = Bundle.main.infoDictionary ?? [:]

        let sdkKey = (info["LINKSENSE_SDK_KEY"] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let host = (info["LINKSENSE_APP_LINK_HOST"] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""

        return SampleConfig(
            sdkKey: sdkKey.isEmpty ? placeholderKey : sdkKey,
            appLinkHost: host.isEmpty ? "example.invalid" : host
        )
    }
}
