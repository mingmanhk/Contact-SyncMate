# Contact SyncMate

A native macOS menu bar app that keeps Google Contacts and Apple Contacts (iCloud / On My Mac) in perfect sync.

## Project Status

🚧 **In Development** - Foundation complete, core features in progress

### ✅ Completed

- [x] Menu bar app architecture with SwiftUI
- [x] Comprehensive settings system with AppStorage
- [x] Onboarding flow UI
- [x] Settings window with tabbed interface
- [x] Core data models (AppState, SyncSession, SyncResult)
- [x] Mac Contacts connector (using Contacts framework)
- [x] Google Contacts connector interface (OAuth & API pending)
- [x] Unified contact model with merge & duplicate detection
- [x] Sync engine architecture

### 🚧 In Progress

- [ ] Google OAuth implementation
- [ ] Google People API integration
- [ ] Core Data persistence for contact mappings
- [ ] Manual sync preview UI
- [ ] Sync execution logic
- [ ] Background auto-sync agent

### 📋 Planned

- [ ] Sync history viewer
- [ ] Duplicate resolver UI
- [ ] Rollback/undo functionality
- [ ] Notification Center integration
- [ ] Localization (English, Chinese)
- [ ] Export logs feature
- [ ] CLI support

## Architecture

### Core Components

```
Contact SyncMate
├── UI Layer (SwiftUI)
│   ├── Menu Bar (AppDelegate)
│   ├── Settings Window (Tabbed)
│   ├── Onboarding Flow
│   └── Manual Sync Preview (TODO)
│
├── Data Models
│   ├── AppState.swift - Central observable state
│   ├── AppSettings.swift - User preferences (AppStorage)
│   ├── UnifiedContact.swift - Normalized contact model
│   └── SyncEngine models (SyncSession, SyncResult, etc.)
│
├── Connectors
│   ├── MacContactsConnector.swift - Contacts.framework integration
│   └── GoogleContactsConnector.swift - People API client
│
├── Sync Engine
│   ├── SyncEngine.swift - Orchestrates sync operations
│   ├── ContactMapper - Converts between formats
│   └── ContactMappingStore - Persists ID mappings (TODO: Core Data)
│
└── Background Agent (TODO)
    └── Auto-sync scheduler with conditions
```

### Data Flow

```
┌─────────────┐         ┌──────────────┐         ┌──────────────┐
│   Google    │◄────────┤     Sync     ├────────►│  Mac Contacts│
│  Contacts   │         │    Engine    │         │   (iCloud)   │
└─────────────┘         └──────┬───────┘         └──────────────┘
                               │
                               │
                        ┌──────▼───────┐
                        │   Unified    │
                        │   Contact    │
                        │    Model     │
                        └──────────────┘
                               │
                        ┌──────▼───────┐
                        │   Mapping    │
                        │     Store    │
                        │  (Core Data) │
                        └──────────────┘
```

## Key Features

### 🔄 Sync Modes

- **2-Way Sync**: Bidirectional sync with intelligent merge
- **Google → Mac**: Use Google as master
- **Mac → Google**: Use Mac as master
- **Manual Sync**: Preview and approve each change

### 🛡️ Safety Features

- Manual preview before first sync
- Confirm deletions
- Duplicate detection
- Sync history & logs
- Rollback capability (planned)
- Dry run mode

### ⚙️ Settings

**Common Sync Settings**
- Sync deleted contacts
- Sync photos
- Filter by groups/labels
- Merge behavior (1-way vs 2-way)
- Postal country code sync
- Batch Google updates

**Manual Sync Settings**
- Detect Google duplicates
- Confirm pending deletions
- Force update all contacts
- Dry run mode

**Auto Sync Settings**
- Enable/disable background sync
- Update interval (5min - daily)
- Conditions: power, WiFi, idle

**Other Settings**
- Language selection
- Menu bar icon style
- Dock icon visibility

## Development Setup

### Prerequisites

- macOS Sonoma or later
- Xcode 15+
- Swift 5.9+
- Google Cloud project with People API enabled
- OAuth client ID for macOS

### Build & Run

1. Clone the repository
2. Open `Contact SyncMate.xcodeproj` in Xcode
3. Set up Google OAuth credentials (see OAuth Setup below)
4. Build and run (⌘R)

### OAuth Setup (TODO)

1. Go to Google Cloud Console
2. Create a new project or select existing
3. Enable People API
4. Create OAuth 2.0 credentials (macOS app)
5. Add redirect URI: `com.googleusercontent.apps.YOUR_CLIENT_ID:/oauthredirect`
6. Add credentials to project

### Required Entitlements

The app requires the following entitlements:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.personal-information.contacts</key>
<true/>
```

## Usage

### First Time Setup

1. Launch the app - it appears in your menu bar
2. Complete the onboarding wizard:
   - Grant Contacts permission
   - Sign in to Google
   - Choose Mac account (iCloud/On My Mac)
   - Select initial sync strategy
3. Run your first manual sync with preview
4. Optionally enable auto-sync

### Daily Use

- **Menu Bar Icon**: Click to access sync commands
- **Manual Sync**: Review changes before applying
- **Auto Sync**: Set it and forget it
- **View History**: Check what was synced
- **Settings**: Customize behavior anytime

## Technical Details

### Contact Mapping

Each synced contact pair is stored with:
- Google resourceName (e.g., `people/c1234567890`)
- Mac contact identifier (UUID)
- Last synced timestamp
- Google etag (for change detection)

### Incremental Sync

- **Google**: Uses sync tokens from People API
- **Mac**: Listens to `CNContactStoreDidChange` notifications
- Only changed contacts are processed

### Merge Strategy

When contacts differ in 2-way sync:
- Non-empty values preferred over empty
- Multi-value fields (phones, emails) are unioned
- Last modified timestamp breaks ties
- User can set field-level rules (planned)

### Performance

- Batch operations (up to 200 contacts per Google API call)
- Background processing with progress updates
- Efficient change detection with sync tokens
- Local caching of contact mappings

## Privacy & Security

- **100% Local**: No external servers (except Google/Apple APIs)
- **Keychain**: OAuth tokens stored securely
- **No Tracking**: No analytics or telemetry
- **User Control**: You decide what syncs and when

**See our [Privacy Policy](PRIVACY_POLICY.md) and [Terms of Use](TERMS_OF_USE.md) for complete details.**

## Roadmap

### v1.0 (Current)
- Core sync functionality
- Manual sync with preview
- Auto sync with scheduling
- Basic settings & preferences

### v1.1 (Future)
- Sync between two Google accounts
- Smart duplicate resolver with UI
- Rollback & undo last sync
- Field-level sync rules

### v1.2 (Future)
- Multiple sync profiles
- Notification Center integration
- CLI for automation
- Advanced filters per field

## Contributing

This is a personal project, but suggestions and bug reports are welcome!

## License

MIT License - See [LICENSE](LICENSE) file for details

## Legal

- [Privacy Policy](PRIVACY_POLICY.md)
- [Terms of Use](TERMS_OF_USE.md)

## Acknowledgments

- Built with SwiftUI and Contacts framework
- Uses Google People API
- Inspired by the need for a privacy-focused, local-first contact sync solution

---

**Status**: Foundation complete, ready for core feature implementation! 🚀
