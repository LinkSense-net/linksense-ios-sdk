# LinkSense iOS SDK

Native iOS SDK for [LinkSense](https://linksense.net) dynamic-link management
and deferred deep linking, distributed as a Swift package.

- **Minimum iOS**: 16
- **Distribution**: Swift Package Manager (source)
- **Transport**: HTTPS to `https://linksense.net/api/sdk/v1/*`

## Install

```swift
// Package.swift (release)
.package(url: "https://github.com/LinkSense-net/linksense-ios-sdk.git", from: "0.3.0")
```

## Configure

```swift
import LinkSense

// Throws LinkSenseError.invalidSdkKey if the key is malformed.
try LinkSense.shared.configure(
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

## Update a link

Fields you leave out are not sent. Optional fields (URLs, social preview,
`metadata`) also take `.clear`. `name`, `tags` and `iosClipboardEnabled`
cannot be cleared: set `tags: .set([])` or `iosClipboardEnabled: .set(false)`
instead.

```swift
LinkSense.shared.updateLink(
    linkId,
    options: UpdateLinkOptions(name: .set("Spring promo"), ogImageUrl: .clear)
) { result in
    // Result<Link, LinkSenseError>
}
```

## Data collected

No IDFA, and no ATT prompt. The vendor identifier (IDFV) *is* sent, as
`device_id_hash` — the name is historical and no client-side hashing happens.
Fingerprint attributes are purged about an hour after the click. Full list in
[PRIVACY.md](https://github.com/LinkSense-net/linksense-ios-sdk/blob/main/PRIVACY.md).

## Cross-SDK API (0.3.0)

The same surface in every LinkSense SDK. Names differ only where the platform idiom does.

| Concept | iOS (Swift) | Android (Kotlin) | Flutter (Dart) | React Native (TS) |
|---|---|---|---|---|
| Configure (throws on a malformed key) | `try LinkSense.configure(_:)` | `LinkSense.configure(context, config)` | `await LinkSense.configure(config)` | `LinkSense.configure(config)` |
| Start / deferred link | `start()` + `onDeferredDeepLink { }` | `start()` + `onDeferredDeepLink { }` | `start()` + `deferredDeepLinks` stream | `await start()` |
| Link opens | `continueUserActivity(_:handler:)` | `handleIntent(intent) { }` | `deepLinks` stream | `onDeepLink(listener)` |
| Pasted link | `submitPastedLink(_:completion:)` | `submitPastedLink(text)` (no-op, returns null) | `submitPastedLink(text)` | `submitPastedLink(text)` |
| Create / get / update / delete | `createLink` / `getLink` / `updateLink` / `deleteLink` | same, `suspend` | same, `Future` | same, `Promise` |
| Update: leave field / set / clear | `.unchanged` / `.set(v)` / `.clear` | `FieldUpdate.Unchanged` / `Set(v)` / `Clear` | `null` / `FieldUpdate.set(v)` / `FieldUpdate.clear()` | `undefined` / `v` / `CLEAR` |
| Link metadata | `link.metadata` | `link.metadata` | `link.metadata` | `link.metadata` |

| Error | iOS `LinkSenseError` | Android `LinkSenseError` | Flutter | RN `error.code` |
|---|---|---|---|---|
| Not configured | `.notConfigured` | `NotConfigured` | `LinkSenseNotConfiguredException` | `NOT_CONFIGURED` |
| Malformed SDK key | `.invalidSdkKey` | `InvalidSdkKey` | `LinkSenseInvalidSdkKeyException` | `INVALID_SDK_KEY` |
| Bad / revoked key | `.unauthorized` | `Unauthorized` | `LinkSenseUnauthorizedException` | `UNAUTHORIZED` |
| Plan limit / platform not allowed | `.accessDenied(details)` | `AccessDenied(...)` | `LinkSenseAccessDeniedException` | `ACCESS_DENIED` + `error.accessDenied` |
| Rate limited | `.rateLimited(retryAfterSeconds:)` | `RateLimited(retryAfterSeconds)` | `LinkSenseRateLimitedException.retryAfterSeconds` | `RATE_LIMITED` + `error.retryAfterSeconds` |
| Slug taken | `.slugExists` | `SlugExists` | `LinkSenseSlugExistsException` | `SLUG_EXISTS` |
| Validation | `.invalidInput(fieldErrors:)` | `InvalidInput(fieldErrors)` | `LinkSenseInvalidInputException` | `INVALID_INPUT` + `error.fieldErrors` |
| Not found | `.notFound` | `NotFound` | `LinkSenseNotFoundException` | `NOT_FOUND` |

Access-denied details carry the same fields everywhere: `serverMessage`, `upgradeRequired` (false when absent), `plan`, `currentUsage`, `limit` (each optional).

## License

Proprietary. Source available to active LinkSense customers under NDA.
