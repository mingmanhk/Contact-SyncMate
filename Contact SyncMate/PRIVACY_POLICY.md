# Privacy Policy

**Contact SyncMate** · Last updated: 10 August 2026

The authoritative privacy policy is the hosted version:

**<https://mingmanhk.github.io/Contact-SyncMate/privacy.html>**
(source in this repository: [`docs/privacy.html`](../docs/privacy.html))

This file is only a pointer, kept so the repository never carries a second,
drifting copy of the policy. If anything here appears to conflict with the
hosted policy, the hosted policy governs.

## Summary of the current policy

- Contact SyncMate has no servers. Your contacts are never sent to, stored by,
  or processed by the developer.
- Contact data is exchanged with Google — that is the product. It leaves your
  Mac only to reach Google via the People API.
- **Optional AI-assisted duplicate matching:** if — and only if — you switch on
  the explicit consent toggle in Settings → AI Matching (off by default; an API
  key alone does not enable it), limited fields of ambiguous duplicate pairs
  (names, organisation, job title, email addresses, phone numbers) are sent to
  Anthropic (`api.anthropic.com`) under your own API key. Otherwise matching
  runs fully on-device.
- Exactly two OAuth scopes are requested: `…/auth/contacts` and
  `…/auth/userinfo.email`. Google tokens are stored in the macOS Keychain.
- Backup snapshots and sync history are stored **unencrypted** on your disk,
  protected by FileVault only if you have it enabled; the app warns if the
  backup folder you choose is cloud-synced.
- No analytics, no telemetry, no tracking, no data sale. App Store privacy
  label: "Data Not Collected".

Questions: [open an issue on GitHub](https://github.com/mingmanhk/Contact-SyncMate/issues).
