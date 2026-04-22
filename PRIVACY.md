# LinkSense iOS SDK — Privacy Disclosure

LinkSense is deliberately positioned as a low-data attribution SDK. This
document lists every field the SDK sends, when it sends it, and why.

## Summary

| Category                          | Collected? |
|-----------------------------------|------------|
| IDFA                              | **No** — never requested, no ATT prompt |
| Raw IDFV                          | **No** — SHA-256-hashed with per-project salt before wire |
| Raw IP                            | **No** — server hashes with a daily-rotating salt before storage |
| User Agent                        | Yes — server-stored, 14-day retention |
| Device model / OS                 | Yes — for probabilistic fingerprint attribution |
| Battery / storage / RAM           | **No** — deliberately skipped |
| Clipboard                         | Opt-in per app (`enableClipboard`); never read without config opt-in |
| Cross-customer linking            | **No** — per-project salts defeat hash-linking across projects |

## First-launch `/install` request

- `install_idempotency_key` — 32-char URL-safe random (client-generated, persisted in UserDefaults until the server returns 2xx)
- `platform` — `ios`
- `device_id_hash` — SHA-256(IDFV || per-project salt)
- `bundle_id`, `app_version`, `sdk_version`, `os_version`
- `locale`, `timezone_offset`
- `screen_logical_w`, `screen_logical_h`, `pixel_ratio`
- `ua` (user-agent string)
- `clipboard_payload` — only when `enableClipboard=true` AND the clipboard
  content matches `linksense:click_id=<12-char>`. Rejected otherwise.
- `deep_link` — inbound Universal Link URL, when the app was launched
  by one.

## Subsequent requests

Link CRUD (`/links/*`) calls carry nothing beyond the SDK key and the
request body (fields the user supplied).

## Retention

- `click_fingerprints` — 14 days.
- `app_installs` — retained for analytics.
- `attribution_matches` — retained for analytics.

## Your data, your control

Revoking an SDK key stops all future calls from apps shipping that key.
Deleting a project deletes every row.
