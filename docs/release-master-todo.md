# LawRelay beta checklist

Reviewed 29 October 2026. Current release: 0.10.0.

Open, free beta for lawyers listed on advocaat.be. No invitation or cohort limit. Directory and email verification are required. Keep client names, case facts, documents and privileged material off the platform.

## Completed

- [x] Live HTTPS site in NL/FR/DE/EN, English URL slugs and language switching.
- [x] Public AGPL source, SemVer releases and source/version links in the footer.
- [x] Signup, directory/email verification, firm boundaries, private-record access and suspended-account protections.
- [x] Recoverable verification-delivery failures, bounded confirmation-handoff retries and useful directory-check feedback.
- [x] Separate admin password/MFA portal, member two-factor authentication, protected recovery and verified email changes.
- [x] Assignment/proposal flows, optional indicative rates, profile-import preview and [localized notifications with retries/history](ops/notifications.md).
- [x] Internal security fixes, translation checks, keyboard/responsive/axe checks and Chrome/Edge/Firefox journeys. See [QA](ops/beta-thorough-qa.md), [dated evidence](ops/beta-ops-checks.md) and [CI](https://github.com/bg-ghub/lawrelay/actions/workflows/ci.yml).
- [x] Backups, isolated restore/compatible-image drills, HTTPS/readiness/queue probes and owner alerts. [Operations evidence](ops/beta-ops-checks.md).
- [x] Operator contact details, terms/privacy, [support playbook](ops/support.md), [data register](ops/data-register.md) and protected [privacy review packages](ops/privacy-operations.md).
- [x] Professional verification and password emails reached the operator; member sign-in and admin MFA were checked live.
- [x] Daily cleanup of resolved support conversations through existing Migadu, with hold/draft safeguards and missed-run alerts.

## Finish during the beta

- [ ] Complete the [real two-lawyer trial](ops/beta-review-handoff.md) when the second lawyer joins; record actual results and feedback.
- [ ] Operator: review the published terms/privacy and retain account-specific provider-agreement evidence privately.
- [x] Retention periods and hold review are defined. Privacy requests still need a verified, case-by-case decision; shared records are pseudonymised where possible.

## Routine operations

Review support/moderation/privacy intake, mail capacity and failed deliveries, backup results, logs, queues and TLS. Use the [support](ops/support.md), [feedback](ops/beta-feedback.md), [monitoring](ops/external-monitoring.md) and [incident](ops/incident-response.md) guides. Technical recovery drills pass; actual incidents still need the operator to respond. Keep real user evidence outside public GitHub issues.

The existing Migadu admin session has expired; support/privacy/security alias routing still needs a check when account access is available. Use `info@lawrelay.be` for the confirmed contact inbox. No new mail provider is configured.

## Deferred or optional

The operator skipped recipient-side SPF/DKIM/DMARC inspection; it remains unconfirmed. DNS, SMTP and internal-receipt checks are recorded separately.

Paid outside reviews are not beta gates and no quotes should be requested. Specialist language/security/accessibility reviews and physical Safari/iOS/Android or screen-reader checks can be added later when resources are available. They have not been completed; internal tests are not certification.

Pricing stays [archived](archive/pricing.md) and subscriptions stay off. Professional fees remain between lawyers.

## Operational references

- [Deployment](ops/deployment.md)
- [Backup and restore](ops/backup-restore.md)
- [Security and access](ops/secrets-and-access.md)
