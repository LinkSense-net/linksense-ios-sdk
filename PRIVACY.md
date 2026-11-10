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
- `locale`, `timezone_offset`
- `screen_logical_w`, `screen_logical_h`, `pixel_ratio`
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
