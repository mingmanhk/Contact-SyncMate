# Privacy Policy

**Contact SyncMate**  
**Effective Date:** November 11, 2025  
**Last Updated:** November 11, 2025

## Our Commitment to Your Privacy

Contact SyncMate is designed with privacy as a core principle. This Privacy Policy explains how we handle your data when you use our macOS application to sync contacts between Google Contacts and Apple Contacts.

**TL;DR:** We don't collect, store, or transmit your personal data to any servers we control. All processing happens locally on your Mac.

## Information We Do NOT Collect

Contact SyncMate **does not** collect, store, or transmit any of the following to our servers (because we don't have any servers):

- ❌ Your contact information (names, emails, phone numbers, addresses)
- ❌ Your Google account credentials or OAuth tokens
- ❌ Your Apple/iCloud account information
- ❌ Usage analytics or telemetry
- ❌ Crash reports (unless you explicitly send them)
- ❌ Device information or identifiers
- ❌ IP addresses or location data
- ❌ Any personal information whatsoever

## How the App Works

### Local-First Architecture

Contact SyncMate operates entirely on your Mac:

1. **Your Mac** ↔ **Google Contacts** (via Google's API)
2. **Your Mac** ↔ **Apple Contacts** (via Apple's Contacts framework)

There is no third-party server in between. Your data flows directly between:
- Your Mac and Google's servers
- Your Mac and Apple's servers (iCloud or local)

### Data Storage Locations

All data is stored locally on your Mac in standard system locations:

| Data Type | Storage Location | Purpose |
|-----------|-----------------|---------|
| **Contact mappings** | `~/Library/Application Support/Contact SyncMate/` | Maps which Google contact corresponds to which Mac contact |
| **User preferences** | `~/Library/Preferences/com.yourcompany.ContactSyncMate.plist` | Your app settings (sync direction, intervals, etc.) |
| **OAuth tokens** | macOS Keychain | Securely stores Google authentication tokens |
| **Sync history** | `~/Library/Application Support/Contact SyncMate/sync_history.json` | Local log of sync operations |
| **Deduplication decisions** | `~/Library/Application Support/Contact SyncMate/dedup_decisions.json` | Your duplicate resolution preferences |

All of these are standard macOS locations protected by system security.

### Data Access

The app only accesses data you explicitly grant permission for:

- **Contacts Access**: Required to read and write to Apple Contacts (iCloud/On My Mac)
- **Network Access**: Required to communicate with Google's servers via their API
- **Keychain Access**: Required to securely store your Google OAuth tokens

You can revoke these permissions at any time through macOS System Settings.

## Third-Party Services

### Google Services

When you connect your Google account:

- **Authentication**: We use Google OAuth 2.0 for secure sign-in
- **API Access**: We use the Google People API to read and write your Google Contacts
- **Token Storage**: OAuth tokens are stored securely in your Mac's Keychain
- **Data Transfer**: Contact data transfers directly between your Mac and Google's servers

**Google's handling of your data is governed by:**
- [Google Privacy Policy](https://policies.google.com/privacy)
- [Google People API Terms of Service](https://developers.google.com/terms)

### Apple Services

When you sync with Apple Contacts (iCloud):

- **Contacts Framework**: We use Apple's native Contacts framework
- **iCloud Sync**: If you use iCloud Contacts, Apple handles the cloud storage
- **Local Storage**: If you use "On My Mac," contacts are stored locally

**Apple's handling of your data is governed by:**
- [Apple Privacy Policy](https://www.apple.com/legal/privacy/)
- [iCloud Terms of Service](https://www.apple.com/legal/internet-services/icloud/)

## Data Security

### Security Measures

Contact SyncMate implements several security practices:

1. **Keychain Storage**: OAuth tokens are stored in macOS Keychain with system-level encryption
2. **HTTPS Only**: All communication with Google uses encrypted HTTPS connections
3. **No Cloud Storage**: We don't maintain any cloud servers or databases
4. **Sandboxing**: The app runs in a macOS sandbox with minimal permissions
5. **No Third-Party Analytics**: No tracking SDKs or analytics frameworks

### What You Should Know

- **OAuth Tokens**: Your Google OAuth token has limited scope (contacts only) and can be revoked anytime
- **Local Files**: Contact mappings are stored as local files on your Mac
- **System Permissions**: macOS protects your Contacts and Keychain with system-level security
- **No Backdoors**: The app has no mechanism to send your data anywhere except Google/Apple

## Your Rights and Controls

### Data Control

You have complete control over your data:

- **View Mappings**: All contact mappings are stored in plain JSON (viewable with any text editor)
- **Delete Data**: Uninstalling the app removes all local data
- **Revoke Access**: Disconnect Google or revoke Contacts permission at any time
- **Export Logs**: Export sync history for your own records
- **Clear History**: Clear sync history and deduplication decisions from settings

### Data Deletion

To completely remove all app data:

1. **Revoke Google Access**: Settings → Google Account → Disconnect
2. **Uninstall App**: Move Contact SyncMate to Trash
3. **Remove Preferences**: Delete `~/Library/Preferences/com.yourcompany.ContactSyncMate.plist`
4. **Remove App Data**: Delete `~/Library/Application Support/Contact SyncMate/`
5. **Remove Keychain Items**: Open Keychain Access → Search "Contact SyncMate" → Delete

Or use the built-in "Reset All Data" option in app settings.

## Children's Privacy

Contact SyncMate is not directed to children under 13. We do not knowingly collect information from children. If you are under 13, please do not use this app.

## Open Source Transparency

Contact SyncMate is open source. You can:

- **Review the Code**: See exactly what the app does with your data
- **Verify Claims**: Confirm that we don't collect or transmit your data
- **Build from Source**: Compile the app yourself for complete trust

Repository: [github.com/yourcompany/contact-syncmate] (if applicable)

## Data Breach Notification

Since we don't collect or store your data on our servers:

- **No Central Database**: There's no central database to be breached
- **Local Storage Only**: Your data is protected by macOS security
- **Your Responsibility**: Keep your Mac secure with encryption, passwords, and updates

If you lose your Mac or it's compromised, immediately:
1. Revoke Google OAuth access: [Google Account Security](https://myaccount.google.com/permissions)
2. Change your Google password
3. Enable 2-factor authentication

## International Users

Contact SyncMate is available worldwide. Since we don't collect data:

- **No Data Transfer**: We don't transfer your data between countries (except via Google/Apple)
- **GDPR Compliance**: As we don't process personal data, most GDPR obligations don't apply
- **Local Processing**: All processing happens locally on your Mac
- **No Data Residency Issues**: Your data stays where you choose (Google/Apple servers)

## Changes to This Policy

We may update this Privacy Policy from time to time. Changes will be posted with a new "Last Updated" date.

- **Material Changes**: We'll notify you via in-app notice or email (if you've subscribed)
- **Minor Updates**: Check this page for the latest version
- **Continued Use**: Using the app after changes means you accept the new policy

Version history:
- v1.0 (November 11, 2025): Initial privacy policy

## Analytics & Diagnostics

### What We Don't Collect

Contact SyncMate **does not** include:
- ❌ Google Analytics
- ❌ Firebase Analytics
- ❌ Mixpanel or similar services
- ❌ Crash reporting services (Sentry, Crashlytics, etc.)
- ❌ A/B testing frameworks
- ❌ Advertising SDKs
- ❌ Any telemetry whatsoever

### Optional Diagnostics

If you experience issues, you can:
- **Export Logs**: Manually export sync history from the app
- **Send to Developer**: Email logs to us (only if you choose to)
- **No Automatic Reporting**: We never automatically collect or send diagnostic data

## Contact Information

If you have questions about this Privacy Policy:

**Contact SyncMate Privacy**  
Email: privacy@yourcompany.com (update with your email)  
GitHub Issues: [github.com/yourcompany/contact-syncmate/issues] (if applicable)

For Google-related privacy concerns:
- [Google Privacy & Terms](https://policies.google.com/)

For Apple-related privacy concerns:
- [Apple Privacy](https://www.apple.com/privacy/)

## Summary

**In plain English:**

✅ **We don't collect your data** - Period.  
✅ **Everything is local** - Processed on your Mac only  
✅ **Open source** - You can verify our claims  
✅ **You're in control** - Delete everything anytime  
✅ **Direct sync** - Your Mac ↔ Google/Apple (no middleman)  
✅ **Secure storage** - Keychain for tokens, encrypted local files  
✅ **No tracking** - No analytics, telemetry, or ads  

**Bottom line:** Contact SyncMate is a tool that runs on your Mac to help you sync contacts. We don't want your data, we don't collect your data, and we don't transmit your data to anyone except the services you explicitly connect (Google and Apple).

---

**Questions?** Read our [Terms of Use](TERMS_OF_USE.md) or contact us at privacy@yourcompany.com.

*Last updated: November 11, 2025*
