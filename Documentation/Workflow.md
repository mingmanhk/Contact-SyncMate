# Contact SyncMate - Workflow Documentation

This document describes the step-by-step workflows for common operations in Contact SyncMate.

---

## Table of Contents

1. [Initial Setup](#initial-setup)
2. [Manual Sync Workflow](#manual-sync-workflow)
3. [Automatic Sync Workflow](#automatic-sync-workflow)
4. [Deduplication Workflow](#deduplication-workflow)
5. [Google OAuth Authentication](#google-oauth-authentication)
6. [Contact Merge Workflow](#contact-merge-workflow)
7. [Export Workflow](#export-workflow)
8. [Error Recovery](#error-recovery)

---

## Initial Setup

### Step 1: First Launch

1. **Download and Install**
   - Install Contact SyncMate from Mac App Store or DMG
   - Drag to Applications folder
   - Launch app

2. **Grant Permissions**
   ```
   ┌─────────────────────────────────────────────┐
   │  Contact SyncMate needs permission          │
   │  to access your contacts.                   │
   │                                              │
   │  [Deny]                    [OK]            │
   └─────────────────────────────────────────────┘
   ```
   - Click "OK" to grant macOS Contacts access
   - App will open System Preferences if needed

3. **Configure Google OAuth**
   - Open Settings (gear icon)
   - Go to "Google Account" tab
   - Click "Sign in with Google"
   - Complete OAuth flow in browser

4. **Initial Configuration**
   - Choose default sync direction (2-way recommended)
   - Set auto-sync interval (optional)
   - Configure merge preferences
   - Enable/disable photo sync

---

## Manual Sync Workflow

### Overview

Manual sync gives you full control over what changes are applied. Recommended for first sync.

### Step-by-Step

```
┌─────────────────────────────────────────────────────────────┐
│  STEP 1: Choose Sync Type                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  ○ 2-way Sync (Google ↔ Mac)                         │   │
│  │  ○ Google → Mac (one-way)                           │   │
│  │  ○ Mac → Google (one-way)                            │   │
│  │  ● Manual Sync (selected contacts)                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 2: Fetch Contacts                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  [━━━━━━━━━━━━━━━━━━━         ] Fetching Google...  │   │
│  │  [████████████████████████] Fetched 247 contacts    │   │
│  │  [████████████████████    ] Fetching Mac...         │   │
│  │  [████████████████████████] Fetched 189 contacts    │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 3: Analyze Differences                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Changes Detected:                                   │   │
│  │  • 12 contacts will be added to Google              │   │
│  │  • 8 contacts will be added to Mac                  │   │
│  │  • 45 contacts will be updated                      │   │
│  │  • 3 contacts will be merged                        │   │
│  │                                                      │   │
│  │  [Review Changes]         [Cancel]                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 4: Review Changes                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Contact: John Smith                                 │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │ GOOGLE                    │ MAC              │   │   │
│  │  │ Name: John Smith          │ Name: John Smith│   │   │
│  │  │ Email: john@gmail.com     │ Email: -        │   │   │
│  │  │ Phone: -                  │ Phone: 555-0123 │   │   │
│  │  │                           │                  │   │   │
│  │  │ Action: MERGE →          │                  │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  │                                                      │   │
│  │  [← Previous] [Use Google] [Use Mac] [Merge] [Next →]│   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 5: Confirm and Execute                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Ready to sync:                                      │   │
│  │  • 68 changes will be applied                       │   │
│  │  • This cannot be undone                           │   │
│  │                                                      │   │
│  │  [Cancel]                    [Sync Now]              │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 6: Execute Sync                                       │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Syncing...                                          │   │
│  │  [███████████████████       ] 68/68                 │   │
│  │                                                      │   │
│  │  Processing John Smith...                            │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 7: Results                                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  ✓ Sync Complete                                     │   │
│  │                                                      │   │
│  │  Summary:                                            │   │
│  │  • 12 added to Google                                │   │
│  │  • 8 added to Mac                                    │   │
│  │  • 45 updated                                        │   │
│  │  • 3 merged                                          │   │
│  │  • 0 errors                                          │   │
│  │                                                      │   │
│  │  [View Log]              [Done]                      │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Detailed Actions

#### Override Per-Contact Actions

During review, you can override the suggested action:

| Action | Description | Use When |
|--------|-------------|----------|
| **Use Google** | Overwrite Mac with Google version | Google has more complete data |
| **Use Mac** | Overwrite Google with Mac version | Mac has more complete data |
| **Merge** | Combine fields from both | Both have unique information |
| **Skip** | Don't sync this contact | Temporary exclusion needed |
| **Delete Both** | Remove from both sources | Contact is obsolete |

---

## Automatic Sync Workflow

### Overview

Automatic sync runs in the background at configured intervals. Ideal for keeping contacts in sync day-to-day.

### Configuration

```
┌─────────────────────────────────────────────────────────────┐
│  Auto Sync Settings                                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Mode:                                              │   │
│  │  ○ Off                                              │   │
│  │  ● 2-way Sync                                       │   │
│  │  ○ Google → Mac                                     │   │
│  │  ○ Mac → Google                                     │   │
│  │                                                      │   │
│  │  Interval:                                          │   │
│  │  [Every 15 minutes ▼]                               │   │
│  │                                                      │   │
│  │  [✓] Sync deleted contacts                          │   │
│  │  [✓] Sync photos                                    │   │
│  │  [ ] Require confirmation for >10 changes          │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Background Process

```
Timeline: ──────────────────────────────────────────────────────►

Time:     9:00     9:15     9:30     9:45     10:00
           │        │        │        │        │
           ▼        ▼        ▼        ▼        ▼
        [Sync]   [Sync]   [Sync]   [Sync]   [Sync]
           │        │        │        │        │
         Check    Check    Check    Check    Check
         Token    Token    Token    Token    Token
           │        │        │        │        │
         Fetch    Fetch    Fetch    Fetch    Fetch
         Changes  Changes  Changes  Changes  Changes
           │        │        │        │        │
         Apply    Apply    Apply    Apply    Apply
         if any   if any   if any   if any   if any
```

### Conflict Resolution in Auto Sync

When conflicts are detected during auto sync:

1. **Auto-merge if possible** (score ≥ 80)
2. **Log conflict** for manual review (score 50-79)
3. **Skip** low-confidence matches (score < 50)
4. **Notify user** if configured threshold exceeded

---

## Deduplication Workflow

### Overview

Find and merge duplicate contacts within and across sources.

### Step-by-Step

```
┌─────────────────────────────────────────────────────────────┐
│  STEP 1: Scan for Duplicates                              │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Scanning:                                           │   │
│  │  [██████████████              ] 456/1000           │   │
│  │                                                      │   │
│  │  Found: 12 potential duplicate groups               │   │
│  │                                                      │   │
│  │  Estimated time: 2 seconds remaining                │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 2: Review Duplicates                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Duplicate Group 1 of 12                            │   │
│  │                                                      │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │ Match Score: 92% (High Confidence)          │   │   │
│  │  │                                              │   │   │
│  │  │ Contact A                Contact B          │   │   │
│  │  │ ─────────                ─────────          │   │   │
│  │  │ John Smith              John Smith          │   │   │
│  │  │ john@gmail.com          john.smith@work.com │   │   │
│  │  │ 555-0123               555-0199             │   │   │
│  │  │ [Google]               [Mac]               │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  │                                                      │   │
│  │  Suggested Action: [Merge Contacts ▼]              │   │
│  │                                                      │   │
│  │  [Previous]  [Skip Group]  [Merge]  [Next]         │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 3: Merge Preview                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Preview Merged Contact:                             │   │
│  │                                                      │   │
│  │  Name: John Smith                                   │   │
│  │  Emails: john@gmail.com, john.smith@work.com        │   │
│  │  Phones: 555-0123, 555-0199                        │   │
│  │  Source: Merged (Google + Mac)                     │   │
│  │                                                      │   │
│  │  Keep original contacts? [✓]                      │   │
│  │                                                      │   │
│  │  [Cancel]              [Confirm Merge]            │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 4: Execute Merges                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Merging contacts...                                │   │
│  │                                                      │   │
│  │  Progress: 5 of 12 groups processed                 │   │
│  │  [█████████████████████       ]                     │   │
│  │                                                      │   │
│  │  Current: Merging John Smith...                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  STEP 5: Results                                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  ✓ Deduplication Complete                            │   │
│  │                                                      │   │
│  │  Results:                                            │   │
│  │  • 12 duplicate groups found                       │   │
│  │  • 8 groups auto-merged                            │   │
│  │  • 3 groups merged with confirmation               │   │
│  │  • 1 group skipped                                 │   │
│  │                                                      │   │
│  │  Total contacts reduced: 23 → 12                  │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Scoring Algorithm

```
Match Score Calculation:

Name Similarity:     40% weight
├─ Exact match:      100 points
├─ 1 char diff:      90 points
├─ 2 char diff:      80 points
└─ Levenshtein calc: dynamic

Email Match:         30% weight
├─ Exact match:      100 points
└─ Domain match:     50 points

Phone Match:         20% weight
├─ Exact match:      100 points
├─ Last 7 match:     90 points
└─ Normalized match: 80 points

Other Fields:        10% weight
├─ Organization:     up to 50 points
└─ Address:          up to 50 points

Thresholds:
├─ Auto-merge:       ≥80 score
├─ Confirm:            50-79 score
└─ Ignore:             <50 score
```

---

## Google OAuth Authentication

### Step-by-Step Flow

```
┌─────────────────────────────────────────────────────────────┐
│  STEP 1: Initiate OAuth                                   │
│                                                             │
│  User clicks "Sign in with Google"
│                           │
│                           ▼
│  STEP 2: Prepare Auth URL
│  ┌─────────────────────────────────────────────────────┐
│  │  Construct OAuth URL with parameters:                │
│  │  • client_id                                         │
│  │  • redirect_uri                                      │
│  │  • scope (contacts, contacts.readonly)              │
│  │  • access_type=offline                              │
│  │  • prompt=consent                                   │
│  └─────────────────────────────────────────────────────┘
│                           │
│                           ▼
│  STEP 3: Open Browser
│  ┌─────────────────────────────────────────────────────┐
│  │  ASWebAuthenticationSession launches                 │
│  │  browser with Google sign-in page                   │
│  └─────────────────────────────────────────────────────┘
│                           │
│                           ▼
│  STEP 4: User Authenticates
│  ┌─────────────────────────────────────────────────────┐
│  │  Google Sign-in Page:                              │
│  │  • User enters credentials                          │
│  │  • User grants permissions                          │
│  │  • Google redirects to custom scheme                │
│  └─────────────────────────────────────────────────────┘
│                           │
│                           ▼
│  STEP 5: Handle Callback
│  ┌─────────────────────────────────────────────────────┐
│  │  App receives callback:                            │
│  │  com.googleusercontent.apps.XXX:/oauth2redirect   │
│  │  ?code=AUTH_CODE&scope=...                         │
│  └─────────────────────────────────────────────────────┘
│                           │
│                           ▼
│  STEP 6: Exchange Code for Tokens
│  ┌─────────────────────────────────────────────────────┐
│  │  POST to https://oauth2.googleapis.com/token        │
│  │  Body:                                             │
│  │    code=AUTH_CODE                                  │
│  │    client_id=XXX                                   │
│  │    client_secret=XXX                               │
│  │    grant_type=authorization_code                   │
│  └─────────────────────────────────────────────────────┘
│                           │
│                           ▼
│  STEP 7: Store Tokens
│  ┌─────────────────────────────────────────────────────┐
│  │  Response contains:                                  │
│  │  • access_token (1 hour expiry)                    │
│  │  • refresh_token (permanent)                       │
│  │  • expires_in (3600 seconds)                      │
│  │                                                    │
│  │  Store in Keychain:                                │
│  │  • GoogleAccessToken                              │
│  │  • GoogleRefreshToken                             │
│  │  • GoogleTokenExpiry                              │
│  └─────────────────────────────────────────────────────┘
│                           │
│                           ▼
│  STEP 8: Authenticated State
│  ┌─────────────────────────────────────────────────────┐
│  │  • isAuthenticated = true                         │
│  │  • Fetch user info                                  │
│  │  • Enable sync buttons                              │
│  └─────────────────────────────────────────────────────┘
```

### Token Refresh Flow

```
Before API Call:
┌─────────────┐
│ Check Token │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ Expired?    │──Yes──┐
└──────┬──────┘       │
       │ No           ▼
       │        ┌─────────────┐
       │        │ Use Refresh   │
       │        │ Token         │
       │        └──────┬──────┘
       │               │
       │               ▼
       │        ┌─────────────┐
       │        │ POST to     │
       │        │ Token Endpoint│
       │        └──────┬──────┘
       │               │
       ▼               ▼
┌─────────────┐ ┌─────────────┐
│ Use Token   │ │ Store New   │
└─────────────┘ │ Tokens      │
                └─────────────┘
```

---

## Contact Merge Workflow

### Merge Strategies

When merging two contacts, fields are combined using these rules:

```
┌─────────────────────────────────────────────────────────────┐
│  FIELD MERGE RULES                                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Single-value fields (Name, Organization):                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Prefer non-empty, longer names                     │   │
│  │  • "John" + "John Smith" → "John Smith"           │   │
│  │  • "Acme" + "Acme Inc." → "Acme Inc."            │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Multi-value fields (Phones, Emails):                       │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Union of unique values                             │   │
│  │  • john@gmail.com + john@work.com                  │   │
│  │    → both kept                                     │   │
│  │  • 555-0123 + 555-0123 (duplicate)                │   │
│  │    → kept once                                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Binary fields (Photo):                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Prefer larger/higher quality photo                │   │
│  │  • If both exist, keep larger                      │   │
│  │  • If one exists, use that one                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Notes:                                                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Concatenate with separator                        │   │
│  │  • "From Google" + "From Mac"                      │   │
│  │    → "From Google\n---\nFrom Mac"                  │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Merge Execution

```
1. Validate merge candidates
   ├── Check IDs exist
   ├── Verify sources match expected
   └── Confirm not already merged
   │
   ▼
2. Create merged contact data
   ├── Merge name fields
   ├── Combine multi-value arrays
   ├── Merge organization
   ├── Handle photo
   └── Combine notes
   │
   ▼
3. Update both sources
   ├── Update Google contact
   ├── Update Mac contact
   └── Sync changes to both
   │
   ▼
4. Update mappings
   ├── Link merged contact IDs
   ├── Mark originals as merged
   └── Store merge history
   │
   ▼
5. Cleanup (optional)
   ├── Delete original Google contact
   ├── Delete original Mac contact
   └── Or keep originals marked deprecated
```

---

## Export Workflow

### Export Formats

```
┌─────────────────────────────────────────────────────────────┐
│  EXPORT OPTIONS                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Format:                                                    │
│  ● vCard (.vcf) - Universal format                         │
│  ○ CSV - Spreadsheet compatible                            │
│  ○ JSON - Machine readable                                  │
│                                                             │
│  Scope:                                                     │
│  ● All contacts                                            │
│  ○ Only Google contacts                                     │
│  ○ Only Mac contacts                                       │
│  ○ Selected contacts                                        │
│                                                             │
│  Include:                                                   │
│  [✓] Photos                                               │
│  [✓] Notes                                                │
│  [✓] Custom fields                                        │
│  [ ] Archived contacts                                     │
│                                                             │
│  Destination:                                              │
│  [Choose Folder...] /Users/user/Documents                 │
│                                                             │
│  [Cancel]                              [Export]            │
└─────────────────────────────────────────────────────────────┘
```

### vCard Export Process

```
1. Select contacts to export
   │
   ▼
2. Convert to vCard format (RFC 6350)
   ├── BEGIN:VCARD
   ├── VERSION:3.0
   ├── FN (formatted name)
   ├── N (name components)
   ├── EMAIL
   ├── TEL
   ├── ADR (address)
   ├── ORG
   ├── TITLE
   ├── PHOTO (base64 encoded)
   ├── NOTE
   └── END:VCARD
   │
   ▼
3. Write to .vcf file
   │
   ▼
4. Open destination in Finder
```

---

## Error Recovery

### Common Errors and Recovery

#### Error: "Failed to authenticate with Google"

```
Cause: Token expired or revoked
Recovery:
1. Clear stored tokens from Keychain
2. Re-initiate OAuth flow
3. Re-authorize with Google

UI: [Retry Authentication] [Clear and Re-auth]
```

#### Error: "macOS Contacts access denied"

```
Cause: User denied permission or permission revoked
Recovery:
1. Open System Preferences → Security & Privacy → Privacy
2. Select Contacts
3. Check Contact SyncMate
4. Restart app

UI: [Open System Preferences] [Cancel]
```

#### Error: "Network timeout"

```
Cause: Poor internet connection or API slow
Recovery:
1. Check network connection
2. Retry with exponential backoff
3. Switch to manual sync if persistent

UI: [Retry] [Switch to Manual] [Cancel]
```

#### Error: "Conflict detected during auto-sync"

```
Cause: Changes on both sides since last sync
Recovery:
1. Pause auto-sync
2. Open conflict resolution UI
3. Present side-by-side comparison
4. User selects resolution
5. Resume auto-sync

UI: [Review Conflicts] [Skip for Now] [Cancel Auto-sync]
```

### Rollback Process

If a sync produces unexpected results:

```
1. Open Sync History
2. Find the problematic sync session
3. Select [Restore Contacts]
4. Choose restore point
   ├── Restore Google contacts
   ├── Restore Mac contacts
   └── Restore both
5. Confirm restoration
6. App reverts to pre-sync state
```

---

## Performance Tips

### For Large Contact Databases (1000+ contacts)

1. **Use incremental sync**: Enable sync tokens
2. **Batch operations**: Process in groups of 100
3. **Schedule during off-hours**: Run auto-sync overnight
4. **Disable photo sync**: Reduces data transfer
5. **Filter by groups**: Only sync necessary contacts

### For First Sync

1. **Use manual sync**: Review all changes
2. **Start small**: Sync a group first
3. **Enable backup**: Export before first sync
4. **Be patient**: Initial sync may take several minutes

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘+S | Start manual sync |
| ⌘+R | Refresh contacts |
| ⌘+D | Find duplicates |
| ⌘+E | Export contacts |
| ⌘+, | Open settings |
| ⌘+Q | Quit app |

---

*Last updated: 2026-03-18*
