# ContactBridge for Mac

ContactBridge is a macOS menu bar app that keeps your **Google Contacts** and **Apple Contacts** (iCloud / On My Mac) in sync.

- 2-way or 1-way sync (Google ↔ Mac)
- Manual sync with full preview and per-contact overrides
- Automatic background sync with configurable interval
- Smart safety features: history, delete confirmation, batching, and more

> **Privacy-first:** All sync logic runs locally on your Mac. No external backend.

---

## Features

### Sync Types

- **2-way Sync**  
  Sync changes between **Google** and **Mac** in both directions.

- **Google Contacts → Mac**  
  Use Google as your source of truth and update Mac accordingly.

- **Mac Contacts → Google**  
  Use Mac as your source of truth and update Google accordingly.

- **Manual Sync (Selected Contacts)**  
  Run manual syncs with a **preview screen** and override actions per contact.

---

### Sync Modes

#### Manual Sync

You are fully in control:

1. Choose a sync type:  
   - 2-way Sync  
   - Google Contacts → Mac  
   - Mac Contacts → Google  
   - Manual Sync (selected contacts only)
2. App fetches Google + Mac contacts and computes changes.
3. You get a **preview list** of:
   - Adds, updates, deletes, merges
   - Direction (Google → Mac, Mac → Google)
   - Highlights of changes per contact
4. Override per-contact actions (e.g. “Skip”, “Force Google version”).
5. Confirm to execute the sync and view a post-sync summary.

> Recommended: use manual sync for the **initial** sync.

#### Auto Sync

Enable background sync so your contacts stay up-to-date:

- Modes:
  - Off
  - 2-way Sync
  - Google Contacts → Mac
  - Mac Contacts → Google
- **Update interval**:
  - e.g. 5 min, 15 min, 30 min, 1 hour, 4 hours, daily
- Background agent runs incremental sync using:
  - Google People API sync tokens
  - macOS Contacts change notifications

You can always open **View Sync Status** to see what’s happening.

---

## Common Sync Settings

These settings apply to both manual and auto syncs.

- **Sync Deleted Contacts**  
  - ON: Deleting a previously synced contact on one side will delete it on the other side during the next sync.  
  - OFF: Deletions are not propagated.

- **Sync Photos**  
  - ON: Contact photos are synced.  
  - OFF: Only text/contact fields are synced.

- **Filter Sync by Groups**  
  - Filter by **Mac groups** and/or **Google labels** so only selected contacts are synced.

- **Merge Contacts (2-way)**  
  - ON: During 2-way syncs, contents of matching contacts are merged when necessary (e.g. initial sync).  
  - OFF: One side overwrites the other based on sync direction.

- **Merge Contacts (1-way)**  
  - ON: For 1-way syncs, merge fields instead of full overwrite.  
  - OFF: Target contact is replaced by the source contact (except unique IDs).

- **Sync Postal Country Codes**  
  - ON: Synchronize and normalize country codes for correct international address formatting.  
  - OFF: Leave country codes unchanged.

- **Batch Gmail Updates**  
  - ON: Batch Google contact updates into groups (e.g. 100 per batch) for faster syncs.  
  - OFF: Send updates one-by-one (useful for debugging problematic contacts).

---

## Manual Sync Settings

Extra knobs for manual syncs:

- **Detect Google Duplicates During Sync**  
  Detect and warn about duplicate Google contacts (e.g., same email / phone) before they are synced to Mac.

- **Confirm Pending Deletions**  
  Show a list of contacts that are about to be deleted and ask for confirmation.

- **Force Update All Contacts**  
  Force updating all contacts even if they haven’t changed.  
  Useful for:
  - Fixing mapping issues
  - Applying new normalization rules  
  (Sync will be slower and more API-intensive.)

- **(Optional Advanced) Dry Run Mode**  
  Compute the full diff and show preview, but never write changes.  
  Great for safety checks.

---

## Auto Sync Settings

- **Update Interval**  
  Choose how often auto sync runs in the background.

- **(Optional) Conditions**  
  - Only sync when on AC power
  - Only sync when network is available
  - Only sync when user is idle

---

## Other Settings

- **Select Language**  
  - Default: Use macOS preferred language  
  - Optionally override inside app preferences.

- **Use Black & White Menu Bar Icon**  
  Replace colored menu bar icon with a monochrome icon.

- **Attach App to Menu Bar**  
  - ON: Runs as a menu bar–only app (no Dock icon).  
  - OFF: Also shows in Dock as a normal macOS app.

---

## Tips Before First Sync

To avoid duplicates and surprises:

1. **Grant Contacts permission**  
   - macOS: System Settings → Privacy & Security → Contacts  
   - Ensure ContactBridge has access.

2. **Configure Mac contact accounts**  
   - Mac contacts may be composed of multiple accounts (iCloud, On My Mac, etc.).  
   - By default, ContactBridge syncs **Google ↔ iCloud** (if available) or **Google ↔ On My Mac**.

3. **Clean Google duplicates**  
   - Visit https://contacts.google.com/suggestions  
   - Merge obvious duplicates before your first sync.

4. **Initial sync strategy**  
   - If **Google** is your master list: use **Google Contacts → Mac** first.  
   - If **Mac** is your master: use **Mac Contacts → Google**.  
   - Otherwise: run a 2-way manual sync with preview and review conflicts.

5. **Disable built-in Google Contacts on macOS**  
   - System Settings → Internet Accounts → Google → turn off **Contacts**.  
   - Let ContactBridge handle Google ↔ iCloud/Mac. This reduces duplicate risk.

---

## Accounts to Sync

From the menu bar, go to **Accounts to Sync**:

- **Gmail Account to Sync**  
  - Sign in to the Google account you want to sync and grant contacts access.

- **Mac Account to Sync**  
  - Default: **Auto (recommended)**  
    - If you have an iCloud account: iCloud Contacts ↔ Gmail.  
    - Otherwise: On My Mac Contacts ↔ Gmail.
  - **All**: Sync all Mac contact accounts except read-only ones (e.g. Facebook).
  - Or choose a **specific account**: iCloud / On My Mac / other supported stores.

---

## Enhanced Features (Roadmap)

Planned enhancements that make ContactBridge stand out:

- **Sync between two Google accounts**  
  - Google A ↔ Google B (via Mac or direct mapping).

- **Smart Duplicate Resolver**  
  - Fuzzy matching for similar names/emails/phones.  
  - Side-by-side UI to merge duplicates before sync.

- **Rollback / Undo Last Sync**  
  - Auto-create snapshots:
    - Export affected Mac contacts to `.vcf`.  
    - Tag Google contacts with a backup label.  
  - “Revert last sync” button.

- **Field-Level Rules**  
  - Example:
    - “Always trust Google for company & title.”
    - “Always keep Mac photos.”
    - “Don’t sync notes.”

- **Multiple Sync Profiles**  
  - “Personal”: Google personal ↔ iCloud (family & friends)  
  - “Work”: Google Workspace ↔ On My Mac (business contacts)

- **Notification Center Integration**  
  - Show macOS notification after each auto sync:
    - Example: “Synced 120 contacts (3 updated, 1 deleted, 0 errors).”

- **CLI / Automation**  
  - Command-line interface:
    - `contactbridge sync --mode=2way`  
  - For power users, scripts, or CI-like automation.

---

## Architecture

### High-Level

- **Platform:** macOS
- **Language:** Swift + SwiftUI (with AppKit where needed, e.g., menu bar)
- **Backend:** None (local only)
- **APIs:**
  - macOS `Contacts.framework` for Mac contacts
  - Google **People API** for Google contacts
  - macOS Keychain for credential storage

### Main Components

1. **UI Layer**
   - Menu bar icon & dropdown
   - Settings window
   - Manual sync preview UI
   - History & status UI

2. **Sync Engine**
   - Orchestrates fetch → diff → apply pipeline.
   - Handles conflict resolution and merges.

3. **Connectors**
   - `GoogleConnector`  
     - OAuth sign-in, token refresh  
     - Uses People API (incremental sync with sync tokens).
   - `MacContactsConnector`  
     - Uses `CNContactStore` for read/write  
     - Uses `CNContactStoreDidChange` notifications.

4. **Mapping & Storage**
   - Local DB (Core Data or SQLite) for:
     - Contact ID mappings (Google ↔ Mac)
     - Sync sessions & history
   - Separate layer to unify contact model and mapping rules.

---

## Development Setup

### Prerequisites

- macOS Sonoma or later (recommended)
- Xcode (latest)
- A Google Cloud project with:
  - People API enabled
  - OAuth client ID for macOS

### Basic Steps

1. Clone repo:

   ```bash
   git clone https://github.com/your-org/contactbridge-mac.git
   cd contactbridge-mac
