# LinkSense iOS SDK — Privacy Disclosure

LinkSense is deliberately positioned as a low-data attribution SDK. This
document lists every field the SDK sends, when it sends it, and why.

## Summary

| Category                          | Collected? |
|-----------------------------------|------------|
| IDFA                              | **No** — never requested, no ATT prompt |
| Raw IDFV                          | Yes — sent as `device_id_hash` and stored server-side. **Not** hashed on-device |
| Raw IP                            | **No** — server hashes with a per-account salt before storage |
| User Agent                        | Yes — server-stored, purged ~1 hour after the click |
| Device model / OS                 | Yes — for probabilistic fingerprint attribution, purged ~1 hour after the click |
| Battery / storage / RAM           | **No** — deliberately skipped |
| Clipboard                         | Opt-in per app (`enableClipboard`) **and** per link; read at most once per install, and only when it already holds a web URL |
| Cross-customer linking            | Salts are per **account**, so two projects owned by the same account share one |

## First-launch `/install` request

- `install_idempotency_key` — 32-char URL-safe random (client-generated, persisted in UserDefaults until the server returns 2xx)
- `platform` — `ios`
- `device_id_hash` — the raw IDFV. The name is historical and misleading: no
  client-side hashing is performed. Tracked for correction.
- `bundle_id`, `app_version`, `sdk_version`, `os_version`
- `locale`, `language`, `timezone_offset`
- `screen_logical_w`, `screen_logical_h` (portrait-normalised), `pixel_ratio`
- `ua` (user-agent string)
- `clipboard_payload` — the 12-char `click_id` from a LinkSense link on the
  pasteboard. Sent only when `enableClipboard=true`, only on the first launch,
  and only when the pasteboard already looks like a web URL (checked with
  `UIPasteboard.detectPatterns`, which reads no content and shows no prompt).
  Any other clipboard content is rejected without being transmitted.
  **iOS shows a paste notification when the SDK reads the pasteboard** — that
  is an OS behaviour no app can suppress. `LinkSensePasteButton` /
  `submitPastedLink(_:)` avoid it because the user's own tap grants access.
- `deep_link` — inbound Universal Link URL, when the app was launched
  by one.

`/install` is sent once per install. Once the server acknowledges it, later
launches send nothing. If it fails, the same body (same idempotency key, same
fingerprint) is kept in UserDefaults and resent on the next cold start, for up
to 24 hours.

## `/deferred-match` request

Only when `/install` succeeded but matched nothing (no `deep_link`, no
`match_method`), the SDK asks again up to twice, about 1.5 s and 5 s after the install.
Each request resends **the same fields as the `/install` body above**,
including the raw IDFV, plus `app_install_id` (the server's id for the
install, which the SDK keeps in UserDefaults). No new data is collected for it.

## `/open` request

Each Universal Link forwarded through `continueUserActivity(_:handler:)` sends
`platform`, the link URL (the server keeps only its path and query),
`bundle_id`, the raw IDFV as `device_id_hash`, `app_version` and
`sdk_version`. Nothing else.

## Subsequent requests

Link CRUD (`/links/*`) calls carry nothing beyond the SDK key and the
request body (fields the user supplied).

## Retention

Two different clocks apply to a click, because two different things are stored:

- **Fingerprint attributes** (user agent, hashed IP, device model, OS, locale,
  timezone, screen geometry) — **~1 hour**. These exist only to support
  probabilistic install matching, and that window is one hour. A scheduled job
  nulls them once it closes; because it runs every five minutes, worst-case
  retention is about 65 minutes.
- **Click reference** (`click_id` and the link it points at) — **14 days**.
  This is what deterministic attribution uses: a Play Install Referrer token,
  a clipboard payload or a Universal Link carries an exact `click_id`, so no
  device data is needed to resolve it. It holds no fingerprint attributes.

- `app_installs` — retained for analytics.
- `attribution_matches` — retained for analytics.

## Your data, your control

Revoking an SDK key stops all future calls from apps shipping that key.
Deleting a project deletes every row.
