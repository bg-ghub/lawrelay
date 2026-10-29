# Changelog

All notable changes to LawRelay are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and uses Git tags prefixed with `v`.

## [Unreleased]

## [0.10.0] - 2026-10-29

### Added

- Daily cleanup of resolved support conversations and linked Sent copies through the existing Migadu mailbox.
- Private closure timestamps, cleanup health checks and encrypted state backups.

## [0.9.0] - 2026-10-29

### Added

- Scheduled retention cleanup, time-limited holds and protected member-account erasure.
- A private deletion ledger that replays reviewed erasures before restored traffic resumes.

### Changed

- Publish retention periods in NL/FR/DE/EN and keep encrypted backups for 30 days.
- Use “confrater” in the Dutch homepage and simplify the beta note.

## [0.8.7] - 2026-10-29

### Fixed

- Retry directory-confirmation handoffs when the mail job cannot be queued.
- Show whether the directory-confirmation email has actually been sent.
- Update the existing Migadu setup and bounce-handling notes.

## [0.8.6] - 2026-10-29

### Fixed

- Keep signup and saved corrections recoverable when verification delivery cannot be queued.
- Retry temporary verification failures and show actionable directory-check guidance.
- Clarify manual privacy-request handling and keep paid reviews out of the beta requirements.

## [0.8.5] - 2026-10-29

### Fixed

- Clarify that confidential details are shared only with the chosen colleague after agreement.

## [0.8.4] - 2026-10-29

### Fixed

- Explain assignment visibility and sharing confidential details with the chosen colleague after agreement.

## [0.8.3] - 2026-10-29

### Fixed

- Keep the optional indicative-price label short and remove its explanatory hint.

## [0.8.2] - 2026-10-29

### Fixed

- Explain that leaving the guideline rate empty invites bids, and remove the example amount.

## [0.8.1] - 2026-10-29

### Fixed

- Make assignment guideline rates optional and show a localized "To be agreed" when no amount is entered.

## [0.8.0] - 2026-10-29

### Added

- Protected privacy export review packages and non-mutating erasure inventories.

### Fixed

- Require completed MFA for personalized homepage content and preserve session revocation during two-factor actions.
- Recheck professional verification before sending assignment notifications.
- Include notification delivery health in the five-minute host check.
- Simplify the footer, clarify privacy retention and enlarge the notification read button.

## [0.7.0] - 2026-10-29

### Added

- Preview details from your linked advocaat.be profile before saving settings.
- Complete assignment notifications, with individual localized emails, delivery retries and an in-app history.

### Fixed

- Suppress outdated event emails and exclude withdrawn or declined candidates from cancellation notices.

## [0.6.2] - 2026-10-29

### Fixed

- Lock administrator email and password against self-service changes, including old reset links. Recovery uses a protected server terminal.
- Translate long-password validation errors in all four languages.

## [0.6.1] - 2026-10-29

### Fixed

- Separate administrator accounts from managed users and marketplace access.
- Show each user's two-factor status and clean up admin navigation.
- Keep archived beta-access controls out of the beta interface.

## [0.6.0] - 2026-10-29

### Added

- Optional two-factor authentication in account settings, with QR setup and single-use recovery codes.

## [0.5.1] - 2026-10-29

### Fixed

- Show a scannable QR code during administrator authenticator setup.

## [0.5.0] - 2026-10-29

### Added

- Dedicated administration at admin.lawrelay.be with password/MFA login and a separate browser session.

### Fixed

- Warn before a language switch discards unfinished form entries.
- Clear old closure details when reports or privacy requests are reopened, with an atomic audit record.

## [0.4.7] - 2026-10-29

### Fixed

- Prevent MFA setup from replacing an existing authenticator; handle expired directory links safely.
- Enforce assignment deadlines, reject invalid amounts, preserve cents and failed-form values, and retain dashboard history.
- Allow Turbo's progress-bar styling through the existing CSP nonce.

### Changed

- Remove platform pricing and billing navigation from the free beta; archive the former subscription idea without committing to paid plans.

## [0.4.6] - 2026-10-29

### Changed

- Added a compact product bar linking to the matching WetWijzer language edition and Praxis.
- Highlighted the free open-source beta and clarified that future income will primarily cover hosting.
- Prepared short bar-newsletter invitations in four languages and recorded external reviewer options.

## [0.4.5] - 2026-10-29

### Fixed

- Clearer recovery from expired password links; links for deleted accounts return to the reset form.
- Larger sign-in sidebar link targets and an accessible label for the homepage example.

### Added

- Browser coverage for two-account signup, both email confirmations, posting, responding, selection and password recovery.
- Updated operations and isolated restore/rollback evidence; a short handoff for the remaining outside reviews.

## [0.4.4] - 2026-10-29

### Changed

- Shorter, plainer copy across the website and all seven emails in NL, FR, DE and EN.
- Removed repeated introductions, sidebars and tutorials; simplified pricing and form layouts.

## [0.4.3] - 2026-10-29

### Added

- A visible GitHub source link, open-source license badge and running release version in the website footer, localized in all four languages.
- Direct operator and contact details on terms and privacy pages, with the official professional profile and updated directory-verification and source-code disclosures.

### Changed

- Shorter legal headings, field labels and footer copy; removed repetitive introductions and boilerplate.

## [0.4.2] - 2026-10-29

### Fixed

- Complete NL/FR/DE/EN dates, numbers, validation messages, assignment deadline errors and admin activity/status labels.
- Send assignment cancellation emails in each recipient's language.
- Preserve the same production language fallback policy as the application.

### Added

- Strict translation checks, catalog parity/duplicate detection, and populated page/email rendering coverage in all four languages, including an isolated production check in CI.

## [0.4.1] - 2026-10-28

### Fixed

- Translate password-reset expiry text in both HTML and plain-text emails across NL, FR, DE and EN, using the configured token lifetime.

## [0.4.0] - 2026-10-28

### Added

- Dedicated administrator sign-in with a password followed by authenticator verification.
- Password-confirmed email changes in settings, with confirmation at the new address, a fresh official-directory check, and sign-out of other devices.

### Fixed

- Return administrators to the admin area after email confirmation.
- Use the requested Dutch wording for outsourcing assignments.

## [0.3.0] - 2026-10-28

### Added

- MFA-protected user administration with search, filters, account details, audited identity edits, suspension/restoration and session revocation.
- Administrator navigation and a direct user-management landing page after sign-in.

### Fixed

- Suspended accounts cannot sign in, reuse sessions, or activate verification through old links or queued directory checks. Firm and colleague access remain unchanged.

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

[Unreleased]: https://github.com/bg-ghub/lawrelay/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/bg-ghub/lawrelay/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/bg-ghub/lawrelay/compare/v0.8.7...v0.9.0
[0.8.7]: https://github.com/bg-ghub/lawrelay/compare/v0.8.6...v0.8.7
[0.8.6]: https://github.com/bg-ghub/lawrelay/compare/v0.8.5...v0.8.6
[0.8.5]: https://github.com/bg-ghub/lawrelay/compare/v0.8.4...v0.8.5
[0.8.4]: https://github.com/bg-ghub/lawrelay/compare/v0.8.3...v0.8.4
[0.8.3]: https://github.com/bg-ghub/lawrelay/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/bg-ghub/lawrelay/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/bg-ghub/lawrelay/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/bg-ghub/lawrelay/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/bg-ghub/lawrelay/compare/v0.6.2...v0.7.0
[0.6.2]: https://github.com/bg-ghub/lawrelay/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/bg-ghub/lawrelay/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/bg-ghub/lawrelay/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/bg-ghub/lawrelay/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/bg-ghub/lawrelay/compare/v0.4.7...v0.5.0
[0.4.7]: https://github.com/bg-ghub/lawrelay/compare/v0.4.6...v0.4.7
[0.4.6]: https://github.com/bg-ghub/lawrelay/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/bg-ghub/lawrelay/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/bg-ghub/lawrelay/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/bg-ghub/lawrelay/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/bg-ghub/lawrelay/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/bg-ghub/lawrelay/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/bg-ghub/lawrelay/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/bg-ghub/lawrelay/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/bg-ghub/lawrelay/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/bg-ghub/lawrelay/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/bg-ghub/lawrelay/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/bg-ghub/lawrelay/releases/tag/v0.1.0
