# Release Checklist — Contact SyncMate

One page, in order, check every box. Sections A–B are one-time; C–F repeat
every release.

---

## A. One-time account setup (blockers)

- [ ] **Bootstrap the local config**: `bash Scripts/bootstrap-config.sh`
      The OAuth loader (`GoogleOAuthConfig.swift`) is gitignored, so a clean
      clone does not build until this script materialises it from the
      committed template (and drops a placeholder `GoogleOAuthConfig.json`).
- [ ] **Accept the latest Apple Program License Agreement**
      developer.apple.com → Account → Membership → agree to PLA.
      *Symptom if skipped: "Unable to process request — PLA Update available".*
- [ ] **Google OAuth client configured** via `Scripts/set-oauth-client.sh`
      1. The client ID lives in `Contact SyncMate/GoogleOAuthConfig.json`,
         which is gitignored — never commit it
      2. Run `Scripts/set-oauth-client.sh <client-id>` (or point it at a
         `GoogleService-Info.plist`) to write/update the file
      3. If a credential was ever committed, treat it as compromised: revoke it
         in Google Cloud Console → Credentials and issue a fresh client
- [ ] **Verify OAuth client** — People API enabled, correct redirect URI,
      bundle's URL scheme matches (`Info.plist → CFBundleURLSchemes`)

## B. One-time signing setup

- [ ] Developer ID Application certificate installed (Xcode → Settings →
      Accounts → Manage Certificates)
- [ ] `notarytool` credentials stored:
      `xcrun notarytool store-credentials "AC_PASSWORD" --apple-id … --team-id … --password <app-specific-password>`

## C. Pre-release verification (every release)

- [ ] `bash Scripts/verify-contact-syncmate.sh` → every phase reports **PASS**
      (do not use bare `xcodebuild test`: the test host is a menu-bar app that
      never exits after the last test, so its exit code is meaningless — the
      script parses the log for the real result)
- [ ] No new warnings introduced (`xcodebuild … 2>&1 | grep warning:`)
- [ ] Manual smoke test (10 min):
  - [ ] Sign in to Google → email shows in Settings → Accounts
  - [ ] Grant Contacts access → contact count appears
  - [ ] Sync Now → menu bar shows `%` progress → completion notification fires
  - [ ] Sync History shows per-change `change.*` entries
  - [ ] Settings → Backups → Create Backup Now → file appears
  - [ ] Toggle dark mode + Increase Contrast + Reduce Motion — UI adapts
  - [ ] Shortcuts app → "Sync Contacts Now" action appears and runs
- [ ] Instruments → Hangs template: no main-thread hangs during a sync

## D. Version bump

- [ ] Increment `MARKETING_VERSION` (user-facing, e.g. 1.2.0 — semver)
- [ ] Increment `CURRENT_PROJECT_VERSION` (build number, monotonic)
- [ ] Update `CHANGELOG.md` with user-facing notes

## E. Archive, notarize, package (Developer ID / direct distribution)

```bash
# 1. Archive
xcodebuild -project "Contact SyncMate.xcodeproj" \
  -scheme "Contact SyncMate" -configuration Release \
  -archivePath build/ContactSyncMate.xcarchive archive

# 2. Export with Developer ID signing
#    ExportOptions.plist is committed at the repo root (method: developer-id).
#    Replace its YOUR_TEAM_ID placeholder with your Team ID first.
xcodebuild -exportArchive \
  -archivePath build/ContactSyncMate.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export

# 3. Notarize + staple
ditto -c -k --keepParent "build/export/Contact SyncMate.app" build/ContactSyncMate.zip
xcrun notarytool submit build/ContactSyncMate.zip --keychain-profile AC_PASSWORD --wait
xcrun stapler staple "build/export/Contact SyncMate.app"

# 4. Package (choose one)
create-dmg "build/export/Contact SyncMate.app" build/   # brew install create-dmg
# or: ditto -c -k --keepParent "build/export/Contact SyncMate.app" ContactSyncMate-<version>.zip
```

- [ ] Verify the privacy manifest shipped in the archive:
      `PrivacyInfo.xcprivacy` present inside the built app bundle
      (declares UserDefaults `CA92.1` and file-timestamp `C617.1`/`DDA9.1`
      API reasons; no tracking)
- [ ] Gatekeeper check on a clean machine/account:
      `spctl -a -vv "Contact SyncMate.app"` → "accepted, source=Notarized Developer ID"

## F. Post-release

- [ ] Tag the commit: `git tag v<version> && git push --tags`
- [ ] Attach the DMG/ZIP to the release page
- [ ] Verify auto-launch + menu bar icon on a fresh install

---

## Mac App Store route (additional, when chosen)

- [ ] Audit file access under sandbox (already enabled; backup folder needs
      user-selected security-scoped bookmarks)
- [ ] App Store Connect listing + privacy nutrition labels
      (Contacts data — synced, not collected; no tracking; "Data Not Collected")
- [ ] Verify the hosted privacy policy
      (`https://mingmanhk.github.io/Contact-SyncMate/privacy.html`) matches
      current in-app claims: AI cloud matching is consent-gated and off by
      default, backups/history are unencrypted on disk, and only the two OAuth
      scopes are requested
- [ ] TestFlight round before submission

## Versioning & tagging (added by the 2026-08-10 audit, issue #81)

Before every submission:

1. Bump `MARKETING_VERSION` if the release warrants it.
2. Set the build number to the commit count so any installed build maps to a
   unique commit: `agvtool new-version -all "$(git rev-list --count HEAD)"`
   (or edit `CURRENT_PROJECT_VERSION` in both configurations).
3. Tag the exact submitted commit:
   `git tag -a "v$(agvtool what-marketing-version -terse1)" -m "App Store submission" && git push origin --tags`
   (or write the version literally, e.g. `git tag -a v1.1 …` —
   `$(MARKETING_VERSION)` is not valid shell and expands to nothing).
