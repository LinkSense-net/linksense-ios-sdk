# LinkSense iOS SDK

Native iOS SDK for [LinkSense](https://linksense.net) dynamic-link management
and deferred deep linking. Closed-source binary distribution via Swift
Package Manager; source available per-customer under NDA.

- **Minimum iOS**: 16
- **Distribution**: Swift Package Manager (binary `.xcframework` on release)
- **Transport**: HTTPS to `https://linksense.net/api/sdk/v1/*`

## Install

```swift
// Package.swift (release)
.package(url: "https://github.com/LinkSense-net/linksense-ios-sdk.git", from: "0.2.0")
```

## Configure

```swift
import LinkSense

LinkSense.shared.configure(
    LinkSenseConfiguration(
        sdkKey: "ls_sdk_<project>_<random>",
        enableClipboard: false, // opt-in; see PRIVACY.md
        logLevel: .off
    )
)
LinkSense.shared.start()

// Deferred deep link after first install
LinkSense.shared.onDeferredDeepLink { url in
    if let url = url {
        router.handle(url)
    }
}
```

The API host (`https://linksense.net`) is baked in at SDK build time and is
not configurable by integrators.

## Data collected

No IDFA, and no ATT prompt. The vendor identifier (IDFV) *is* sent, as
`device_id_hash` — the name is historical and no client-side hashing happens.
Fingerprint attributes are purged about an hour after the click. Full list in
[PRIVACY.md](https://github.com/LinkSense-net/linksense-ios-sdk/blob/main/PRIVACY.md).

## License

Proprietary. Source available to active LinkSense customers under NDA.
