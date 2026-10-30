# LawRelay beta checklist

Reviewed 30 October 2026. Current release: 0.10.1.

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
- [x] Migadu support/privacy/security identities receive into the same inbox as `info@lawrelay.be`; individual delivery tests passed.
- [x] Terms/privacy read-through against current behavior; clarify sharing, retention, transfers and signup acknowledgement in NL/FR/DE/EN.
- [x] Save current provider terms/DPAs and available account context in a restricted private archive outside Git, with sources and checksums.
- [x] Retrieve the existing Hetzner account DPA with Appendix 1 and Migadu's account/subscription record and paid receipt copy; verify private access and archive checksums.
- [x] Three-account synthetic trial: directory-shaped fixtures, confirmations, blank indicative price, competing proposals, selection/non-selection, completion, cancellation and captured email. Also checked manually in an isolated local copy.

## Finish during the beta

- [ ] Collect real participant feedback using the [two-lawyer trial](ops/beta-review-handoff.md) when another lawyer joins. Synthetic workflow checks are complete; inbox arrival and participant feedback remain separate evidence.
- [x] Retention periods and hold review are defined. Privacy requests still need a verified, case-by-case decision; shared records are pseudonymised where possible.

## Routine operations

Review support/moderation/privacy intake, mail capacity and failed deliveries, backup results, logs, queues and TLS. Use the [support](ops/support.md), [feedback](ops/beta-feedback.md), [monitoring](ops/external-monitoring.md) and [incident](ops/incident-response.md) guides. Technical recovery drills pass; actual incidents still need the operator to respond. Keep real user evidence outside public GitHub issues.

## Deferred or optional

The operator skipped recipient-side SPF/DKIM/DMARC inspection; it remains unconfirmed. DNS, SMTP and internal-receipt checks are recorded separately.

Paid outside reviews are not beta gates and no quotes should be requested. Specialist language/security/accessibility reviews and physical Safari/iOS/Android or screen-reader checks can be added later when resources are available. They have not been completed; internal tests are not certification.

Pricing stays [archived](archive/pricing.md) and subscriptions stay off. Professional fees remain between lawyers.

## Operational references

- [Deployment](ops/deployment.md)
- [Backup and restore](ops/backup-restore.md)
- [Security and access](ops/secrets-and-access.md)
