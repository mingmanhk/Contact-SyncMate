# Release Checklist — Contact SyncMate

One page, in order, check every box. Sections A–B are one-time; C–F repeat
every release.

---

## A. One-time account setup (blockers)

- [ ] **Accept the latest Apple Program License Agreement**
      developer.apple.com → Account → Membership → agree to PLA.
      *Symptom if skipped: "Unable to process request — PLA Update available".*
- [ ] **Rotate the Google API key** hardcoded in `GoogleAPIConfig.swift`
      1. Google Cloud Console → Credentials → delete/regenerate the old key
      2. Put the new key in `GoogleOAuthConfig.json` (gitignored) and load it
         from there; remove the literal from source
      3. Treat the old key as compromised (it exists in git history)
- [ ] **Verify OAuth client** — People API enabled, correct redirect URI,
      bundle's URL scheme matches (`Info.plist → CFBundleURLSchemes`)

## B. One-time signing setup

- [ ] Developer ID Application certificate installed (Xcode → Settings →
      Accounts → Manage Certificates)
- [ ] `notarytool` credentials stored:
      `xcrun notarytool store-credentials "AC_PASSWORD" --apple-id … --team-id … --password <app-specific-password>`

## C. Pre-release verification (every release)

- [ ] `xcodebuild -scheme "Contact SyncMate" build` → **BUILD SUCCEEDED**
- [ ] `xcodebuild -scheme "Contact SyncMate" test` → **all tests pass**
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

- [ ] Gatekeeper check on a clean machine/account:
      `spctl -a -vv "Contact SyncMate.app"` → "accepted, source=Notarized Developer ID"

## F. Post-release

- [ ] Tag the commit: `git tag v<version> && git push --tags`
- [ ] Attach the DMG/ZIP to the release page
- [ ] Verify auto-launch + menu bar icon on a fresh install

---

## Mac App Store route (additional, when chosen)

- [ ] Add `com.apple.security.app-sandbox` to entitlements
- [ ] Audit file access under sandbox (backup folder needs user-selected
      security-scoped bookmarks)
- [ ] App Store Connect listing + privacy nutrition labels
      (Contacts data — synced, not collected; no tracking)
- [ ] TestFlight round before submission
