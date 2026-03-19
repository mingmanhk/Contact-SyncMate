# Contact SyncMate - Architecture Documentation

## Overview

Contact SyncMate is a macOS menu bar application that synchronizes contacts between Google Contacts and Apple Contacts (iCloud/On My Mac). The app runs entirely locally with no external backend, ensuring privacy-first contact management.

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐ │
│  │ ContentView  │ │ SettingsView │ │ Deduplication Views  │ │
│  └──────────────┘ └──────────────┘ └──────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    ViewModels / State                        │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐ │
│  │  AppState    │ │ SyncEngine   │ │ DeduplicationCoord   │ │
│  └──────────────┘ └──────────────┘ └──────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Service Layer                              │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐ │
│  │GoogleContacts│ │ MacContacts  │ │ ContactNormalizer    │ │
│  │  Connector   │ │  Connector   │ └──────────────────────┘ │
│  └──────────────┘ └──────────────┐ ┌──────────────────────┐ │
│  ┌──────────────┐ ┌──────────────┐ │ ContactDeduplicator  │ │
│  │GoogleOAuth   │ │ SyncEngine    │ └──────────────────────┘ │
│  │  Manager    │ │Deduplication  │ ┌──────────────────────┐ │
│  └──────────────┘ │  Integration  │ │ ContactMappingStore  │ │
│                   └──────────────┘ └──────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Data Layer                               │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐ │
│  │UnifiedContact│ │ ContactMapping│ │ DeduplicationDecision│ │
│  │   Model     │ │    Store      │ │       Store          │ │
│  └──────────────┘ └──────────────┘ └──────────────────────┘ │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐ │
│  │ SyncHistory │ │  AppSettings │ │  GoogleOAuthConfig   │ │
│  └──────────────┘ └──────────────┘ └──────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   External APIs                              │
│  ┌──────────────────────────┐ ┌──────────────────────────┐ │
│  │    Google People API     │ │   macOS Contacts API     │ │
│  │   (OAuth 2.0 secured)    │ │   (CNContact framework)  │ │
│  └──────────────────────────┘ └──────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. UnifiedContact Model

The `UnifiedContact` struct serves as the canonical representation of a contact, abstracting away differences between Google and Mac contact formats.

**Key Features:**
- Supports both Google resource names and Mac contact identifiers
- Handles multi-value fields (phones, emails, addresses)
- Stores metadata for sync tracking
- Equatable for comparison operations

**Fields:**
- Name components (given, middle, family, prefix, suffix, phonetic)
- Organization (company, department, job title)
- Multi-value arrays (phones, emails, addresses, URLs)
- Dates (birthday, last modified)
- Binary data (photo)

### 2. Sync Engine

The `SyncEngine` orchestrates the synchronization process between Google and Mac contacts.

**Responsibilities:**
- Fetch contacts from both sources
- Compute differences and changes
- Apply changes with conflict resolution
- Track sync progress and errors
- Support manual and automatic sync modes

**Sync Directions:**
- `twoWay`: Bidirectional sync with merge capability
- `googleToMac`: One-way sync from Google to Mac
- `macToGoogle`: One-way sync from Mac to Google

### 3. Deduplication System

A sophisticated scoring-based duplicate detection system.

**Components:**
- `ContactDeduplicator`: Main engine for duplicate detection
- `DeduplicationScoringReference`: Scoring algorithms
- `DeduplicationDecisionStore`: Persistent user decisions
- `DeduplicationCoordinator`: UI coordination

**Scoring Factors:**
- Name similarity (Levenshtein distance)
- Email exact match
- Phone number normalization and match
- Organization match
- Address similarity

**Thresholds:**
- Auto-merge: ≥80 score
- User confirmation: 50-79 score
- Ignore: <50 score

### 4. Connectors

#### GoogleContactsConnector
- Manages Google People API communication
- Handles OAuth authentication via `GoogleOAuthManager`
- Converts Google Person objects to UnifiedContact
- Supports batch operations for efficiency

#### MacContactsConnector
- Wraps macOS Contacts framework (CNContact)
- Handles permission requests
- Converts CNContact to/from UnifiedContact
- Manages contact groups

### 5. OAuth Manager

`GoogleOAuthManager` handles secure authentication:
- ASWebAuthenticationSession for OAuth flow
- Keychain storage for tokens
- Automatic token refresh
- Menu bar mode compatibility

## Data Flow

### Sync Process

```
1. User initiates sync
   │
   ▼
2. SyncEngine.fetchContacts()
   ├── GoogleContactsConnector.fetchAllContacts()
   └── MacContactsConnector.fetchAllContacts()
   │
   ▼
3. Convert to UnifiedContact
   ├── ContactMapper.toUnified(googleContact)
   └── ContactMapper.toUnified(macContact)
   │
   ▼
4. Compute Changes
   └── SyncEngine.computeChanges()
       ├── Match existing contacts
       ├── Detect additions
       ├── Detect updates
       └── Detect deletions
   │
   ▼
5. Deduplication (if enabled)
   └── ContactDeduplicator.detectDuplicates()
       ├── Score potential matches
       ├── Group duplicates
       └── Present for user confirmation
   │
   ▼
6. Apply Changes
   ├── GoogleContactsConnector.applyChanges()
   └── MacContactsConnector.applyChanges()
   │
   ▼
7. Update Mappings
   └── ContactMappingStore.saveMappings()
   │
   ▼
8. Log to SyncHistory
```

### Deduplication Flow

```
1. Detect Duplicates
   ├── Within Google contacts
   ├── Within Mac contacts
   └── Across sources
   │
   ▼
2. Score Matches
   ├── Name similarity (40%)
   ├── Email match (30%)
   ├── Phone match (20%)
   └── Organization/Address (10%)
   │
   ▼
3. Group by Score
   ├── Auto-merge (≥80)
   ├── User confirmation (50-79)
   └── Ignore (<50)
   │
   ▼
4. User Review (if needed)
   ├── Show duplicate groups
   ├── Allow per-contact override
   └── Remember decisions
   │
   ▼
5. Execute Merge
   ├── Merge field values
   ├── Preserve all unique data
   └── Update mappings
```

## Security Considerations

### OAuth Token Storage
- Access tokens stored in macOS Keychain
- Refresh tokens for automatic renewal
- Token expiry tracked with 5-minute buffer
- Secure deletion on logout

### Contact Data
- All processing happens locally
- No external backend or cloud service
- Google API calls use HTTPS
- Minimal data exposure to Google APIs

### Permissions
- macOS Contacts permission required
- Google OAuth consent screen
- User controls all sync operations

## Performance Optimizations

### Batch Operations
- Google API batch updates (100 contacts per batch)
- Reduces API calls and improves speed
- Configurable batch size

### Incremental Sync
- Google sync tokens for change tracking
- Mac Contacts change notifications
- Only fetch modified contacts

### Caching
- UnifiedContact caching during sync
- Mapping store for quick lookups
- Decision store for deduplication patterns

### Background Processing
- Async/await for non-blocking UI
- Progress reporting for long operations
- Cancellation support

## Error Handling

### Retry Logic
- Exponential backoff for API failures
- Token refresh on 401 errors
- Network error recovery

### User Feedback
- Detailed error messages
- Sync status indicators
- Error logging to SyncHistory

### Data Integrity
- Validation before applying changes
- Backup of modified contacts
- Rollback capability

## Extension Points

### Adding New Contact Sources
1. Create new Connector class
2. Implement `fetchAllContacts()` and `applyChanges()`
3. Add source-specific mapping in ContactMapper
4. Update UI for source selection

### Custom Deduplication Rules
1. Extend `DeduplicationScoringReference`
2. Add new scoring algorithms
3. Update thresholds in Configuration
4. Add UI for rule customization

### Sync Hooks
- Pre-sync validation
- Post-sync notifications
- Custom merge strategies

## Build Requirements

- macOS 13.0+
- Xcode 15.0+
- Swift 5.9+
- Frameworks:
  - Contacts
  - AuthenticationServices
  - Security
  - Combine
  - AppKit

## Configuration Files

### GoogleOAuthConfig.swift (Not in repo)
```swift
struct GoogleOAuthConfig {
    let clientId = "YOUR_CLIENT_ID"
    let clientSecret = "YOUR_CLIENT_SECRET"
    let redirectURI = "com.googleusercontent.apps.YOUR_CLIENT_ID:/oauth2redirect"
}
```

### Info.plist
```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>Google OAuth</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>com.googleusercontent.apps.YOUR_CLIENT_ID</string>
        </array>
    </dict>
</array>
```

## Testing Strategy

### Unit Tests
- Contact mapping logic
- Deduplication scoring
- OAuth token management

### Integration Tests
- Sync engine with mock connectors
- Full sync workflow
- Error scenarios

### Manual Testing
- Real Google account sync
- Large contact datasets (1000+)
- Edge cases (empty contacts, special characters)

## Future Enhancements

1. **iCloud Sync**: Support for iCloud-specific features
2. **Contact Groups**: Sync group/label memberships
3. **Conflict UI**: Visual diff for conflicting fields
4. **Import/Export**: vCard and CSV support
5. **Shortcuts**: macOS Shortcuts app integration
6. **Widgets**: Home Screen widgets for sync status

---

*Last updated: 2026-03-18*
