# LinkSense iOS SDK

Native iOS SDK for [LinkSense](https://linksense.net) dynamic-link management
and deferred deep linking. Closed-source binary distribution via Swift
Package Manager; source available per-customer under NDA.

- **Minimum iOS**: 14
- **Distribution**: Swift Package Manager (binary `.xcframework` on release)
- **Transport**: HTTPS to `https://linksense.net/api/sdk/v1/*`

## Install

```swift
// Package.swift (release)
.package(url: "https://github.com/jankokalj/linksense-ios.git", from: "0.1.0")
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

## Data collected

No IDFA. No raw IDFV (SHA-256-hashed client-side with a per-project salt
before it ever leaves the device). No device identifiers beyond the
hashed ID. Full list in
[PRIVACY.md](https://github.com/jankokalj/linksense-ios/blob/main/PRIVACY.md).

## License

Proprietary. Source available to active LinkSense customers under NDA.
