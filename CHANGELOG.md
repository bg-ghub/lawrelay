# Changelog

All notable changes to LawRelay are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and uses Git tags prefixed with `v`.

## [Unreleased]

## [0.2.1] - 2026-10-28

### Fixed

- Bind verification and recovery links to the current email; require explicit email confirmation and enforce password length on the server.
- Require current firm membership to manage assignments and redact MFA codes and professional free text from request logs.
- Improve keyboard navigation, form labels, focus, mobile menus, reduced motion and page landmarks.
- Correct official-directory links and provider locations across NL/FR/DE/EN.

### Added

- External uptime checks, safe alert drills, isolated rollback/restore evidence, and beta support/privacy/feedback runbooks.

## [0.2.0] - 2026-10-28

### Added

- Public `info@lawrelay.be` contact link across all four interface languages.
- Free open beta with official-directory and professional-email verification, automatic access, and disabled paid checkout.
- Published operator details and beta pricing, privacy, terms, and contact copy in NL/FR/DE/EN.
- Production database/storage readiness, deployment preflight, and container smoke checks in CI.
- Private image deployment with Caddy TLS, encrypted off-host backups, restore drills, and operational checks.

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

[Unreleased]: https://github.com/bg-ghub/lawrelay/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/bg-ghub/lawrelay/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/bg-ghub/lawrelay/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/bg-ghub/lawrelay/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/bg-ghub/lawrelay/releases/tag/v0.1.0
