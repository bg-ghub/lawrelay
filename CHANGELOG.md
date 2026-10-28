# Changelog

All notable changes to LawRelay are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and uses Git tags prefixed with `v`.

## [Unreleased]

## [0.1.1] - 2026-10-28

### Fixed

- Preserve executable modes and portable Ruby shebangs for Rails, audit, deployment, and container binstubs on Linux checkouts.

## [0.1.0] - 2026-10-28

### Added

- Lawyer and firm accounts with email verification, password recovery, expiring sessions, and administrator TOTP MFA.
- Verified-lawyer marketplace for structured court cover and legal assignments.
- Firm-scoped proposals, assignment lifecycle, notifications, audit events, and participant-only closed matters.
- Professional profiles, court/practice matching suggestions, and NL/FR/DE/EN interfaces with English URL slugs.
- Pricing and legal-page drafts, privacy-request intake, content reporting, and administrator review queues.
- Manual invoice/Peppol handoff and Mollie webhook foundations with optional posting entitlements.
- Production hardening, CI, deployment/rollback, backup/restore, incident-response, SEO, and readiness foundations.

[Unreleased]: https://github.com/bg-ghub/lawrelay/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/bg-ghub/lawrelay/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/bg-ghub/lawrelay/releases/tag/v0.1.0
