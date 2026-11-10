# LinkSense iOS — Sample App

SwiftUI sample that exercises the SDK end-to-end: configure/start, deferred
deep link, Universal Link, and Link CRUD. Parity with the Android sample at
`linksense-android/sample/`.

## One-time setup

```bash
cp LinkSenseSample/Secrets.xcconfig.example LinkSenseSample/Secrets.xcconfig
# then edit Secrets.xcconfig and fill in real values
open LinkSenseSample.xcodeproj
```

`Secrets.xcconfig` is git-ignored. Its three variables mirror the Android
`local.properties` keys:

| xcconfig key               | Android `local.properties` key |
|----------------------------|--------------------------------|
| `LINKSENSE_SDK_KEY`        | `linksense.sdkKey`             |
| `LINKSENSE_APP_LINK_HOST`  | `linksense.appLinkHost`        |

They flow into the app via `Info.plist` substitution (`$(LINKSENSE_SDK_KEY)`)
and the entitlements file (`applinks:$(LINKSENSE_APP_LINK_HOST)`). The app
reads them at launch through `SampleConfig.load()`.

## What it demonstrates

Five SwiftUI cards, driven by `SampleViewModel`:

1. **Configuration** — masked SDK key, app-link host.
2. **Deferred deep link** — URL delivered to `LinkSense.shared.onDeferredDeepLink { }` after `/install`.
3. **Last universal link** — last URL forwarded through `LinkSense.shared.continueUserActivity(_:handler:)` via `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`.
4. **Link CRUD** — form + four buttons that call `createLink`, `getLink(id:)`, `updateLink`, `deleteLink`.
5. **Last result** — pretty-printed `Link` on success, mapped `LinkSenseError.userFacingMessage` on failure.

## Manual test matrix

- **Cold-install flow**: erase the app from the simulator (`Device → Erase All Content and Settings`, or long-press + delete on the home screen) and relaunch — `onDeferredDeepLink` should fire with either the resolved URL or `nil` on no match.
- **Universal Link**: `xcrun simctl openurl booted https://<LINKSENSE_APP_LINK_HOST>/<slug>`. The card will only update if your host serves a valid `apple-app-site-association` that lists this app's bundle ID (`net.linksense.sample` by default).
- **CRUD**: tap Create → `lastCreatedId` fills in. Tap Get/Update/Delete; the "ID override" field takes precedence if filled.
- **Logging**: `LINKSENSE_DEBUG` is set by default (`logLevel: .debug` in `LinkSenseSampleApp.swift`), so SDK requests/responses log to the Xcode console — watch for `/install` and `/api/sdk/v1/links/*`.

## Notes

- This sample consumes the local Swift Package via `.package(path: "..")`; it does not pin to a tag.
- `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad), `IPHONEOS_DEPLOYMENT_TARGET = 14.0`, matching the package's minimum.
- Code signing is set to Automatic; set your development team in Xcode before running on a device. On Simulator, no signing is needed.
