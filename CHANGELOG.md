# Changelog

## 0.2.0

### Fixed

- **`/install` is now sent once per install, not on every launch.** 0.1.0
  posted a new install on every cold start, so each launch was counted as a
  new install. Once the server has acknowledged the install, later launches
  (and later calls to `start()`) send nothing. `onDeferredDeepLink` still
  fires, with `nil`, on those launches.
- **A failed install is resumed, not recomposed.** If `/install` gives up
  after its retries, the exact request body (same idempotency key, same
  fingerprint) is stored and resent on the next cold start, for up to
  24 hours. The server dedupes it, so a retry never creates a second install.
- **Late click matches are recovered.** When `/install` succeeds but matches
  nothing, the SDK asks `/deferred-match` up to twice (about 1.5 s and 5 s
  after the install) before reporting the install as organic. This covers a click that
  reaches the server a moment after the install. `onDeferredDeepLink` still
  fires exactly once.
- **Retries are gentler.** Backoff now has ±25% jitter, and a `429` waits for
  the server's `Retry-After` (capped at 5 minutes). Each request times out
  after 15 s instead of URLSession's default 60 s.
- **Landscape launches match again.** Screen size is sent portrait-normalised,
  the way Safari reports it at click time, and is read from the active window
  scene on the main thread.
- **Clipboard attribution works.** The clipboard payload is now an `https://`
  link carrying `?click_id=`. The 0.1.0 format (`linksense:click_id=`) was never
  detected as a URL, so the clipboard was never read. The pasteboard is only
  read when it already looks like a web URL, and at most once per install.

### Added

- `LinkSensePasteButton` (SwiftUI) and `LinkSense.shared.submitPastedLink(_:completion:)`:
  attribute from a link the user pastes. The user's tap grants pasteboard
  access, so iOS shows no paste prompt.
- New `LinkSenseError` cases: `.unauthorized`, `.notFound`, `.customPathExists`,
  `.invalidInput(fieldErrors:)`. `fieldErrors` is read from the server's
  `error.details` list; plan-gate errors no longer lose their code.
- **App opens are reported.** `continueUserActivity(_:handler:)` now sends
  `POST /api/sdk/v1/open` with the link URL, so Universal Link opens show in
  analytics. iOS matches Universal Links on-device, so LinkSense never saw
  them before. The report is fire-and-forget and never delays the handler.

### Breaking changes

- Minimum iOS is now **16** (was 14).
- `LinkSenseConfiguration(baseURL:)` is removed. The API host is fixed at
  build time.
- `link(withId:completion:)` is renamed to `getLink(id:completion:)`.
- `UpdateLinkOptions` fields are now `FieldUpdate<T>` (`.unchanged`,
  `.set(value)`, `.clear`) instead of double optionals, except `name`, `tags`
  and `iosClipboardEnabled`, which are `RequiredFieldUpdate<T>` (`.unchanged`,
  `.set(value)`, no `.clear`). The server rejects `null` for those three, so
  clearing them could only fail. To empty `tags`, set `[]`; to turn the
  clipboard off, set `false`.
- `LinkSenseError` has new cases, so an exhaustive `switch` over it needs
  updating.

### Privacy

- The docs now say plainly that the raw IDFV is sent, as `device_id_hash`.
  0.1.0's docs wrongly said it was hashed on-device. The privacy manifest
  declares `DeviceID` as linked. See [PRIVACY.md](PRIVACY.md).

## 0.1.0

First release.
