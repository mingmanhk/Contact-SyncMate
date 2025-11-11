# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Deduplication workflow coordinator (`DeduplicationCoordinator`) scaffolding with scan, decision application, and sync gating.
- Privacy Policy page (`PRIVACY_POLICY.md`).
- Terms of Service page (`TERMS_OF_SERVICE.md`).
- README updates with Legal section linking to policy documents.

### Changed
- Improved logging hooks via `SyncHistory` for deduplication steps and notifications.

### Known Issues
- Build error: `'SyncMode' is ambiguous for type lookup in this context` and `Invalid redeclaration of 'SyncMode'`. Likely due to multiple declarations of `SyncMode`. Consolidate into a single shared definition or namespace it.

## [0.1.0] - 2025-11-11
### Added
- Initial repository setup for Contact SyncMate.
- Core types for deduplication results and decision handling (placeholders/stubs where applicable).

[Unreleased]: https://github.com/your-org/contact-syncmate/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/your-org/contact-syncmate/releases/tag/v0.1.0
