# LawRelay release checklist

Last audited: 29 October 2026. Current release: 0.4.3.

Current scope: an open, free founding beta for lawyers listed on advocaat.be. Registration is not invitation-only and has no cohort cap. Directory and email verification are required before marketplace access. Paid subscriptions remain disabled. Do not enter client names, case facts, pleadings, documents, or privileged material.

This is an engineering and product checklist, not legal advice. A checked item is verified; a draft or an intention is not a completed review.

## Current release status

- [x] Live at [lawrelay.be](https://lawrelay.be) over HTTPS in NL, FR, DE, and EN.
- [x] Open registration for lawyers listed in the official advocaat.be directory; no invitation or cohort limit.
- [x] Directory profile lookup, professional-email confirmation, account email verification, and suspended-account protections are implemented and tested.
- [x] Private assignments, proposals, settings, and admin routes require authentication and authorization.
- [x] Public GitHub source under AGPL-3.0-or-later, authorized by the operator after a full-history secret/private-data review. Production credentials and data remain excluded; private vulnerability reporting is enabled.
- [x] Free-beta deployment on Hetzner with immutable image/version pins; the runtime revision is recorded in the protected `release.env`.
- [x] Automated regressions, static/security scans, and Chrome/Firefox/Edge system checks. The CI link records the current revision's results.
- [x] Off-host backups and isolated restore drill pass (`9d55cfca`); nightly backups and five-minute health checks are enabled. Owner SMTP alerting was tested.
- [x] Production administrator password email completed through Migadu after configuring 10-second connection and 30-second read timeouts. The queue has no failed or pending jobs. Recipient-side inbox/header checks remain below.
- [x] GitHub-hosted Actions starts jobs again under the existing account budget. [CI](https://github.com/bg-ghub/lawrelay/actions/workflows/ci.yml) checks SemVer, security, lint, Rails/browser tests, and the production container; release merges wait for every check to pass.

## Verified controls

- [x] NL/FR/DE/EN locale pages, English URL slugs, language switching, metadata, sitemap, and robots rules.
- [x] Verified-lawyer and firm-scoped marketplace access, closed-assignment authorization, proposal transitions, notifications, reports, and audit events.
- [x] No client-content fields in the initial assignment flow; posting confirmation warns against client names, facts, and documents.
- [x] Admin MFA, verification queue, privacy-request queue, and moderation controls.
- [x] MFA-protected user management: search/filter accounts, inspect verification and sessions, edit basic details, suspend/restore accounts and revoke sessions with audit records. Administrator accounts are protected from edits in this console.
- [x] Dedicated administrator password/MFA sign-in and password-confirmed self-service email changes with new-address confirmation, a fresh directory check and revocation of other sessions.
- [x] Free-beta billing guard: no checkout or payment request in beta; posting entitlement fails closed when billing is enforced.
- [x] Migadu identities and DNS records configured; SMTP authentication, application sender, and contact inbox tested. External recipient-side header alignment remains a monitoring item.
- [x] Production readiness endpoint, container health checks, Caddy HTTPS, canonical `www` redirect, backups, restore drill, health checks, and owner alert route.
- [x] SemVer, changelog, license, secret exclusions and repository secret scans; the footer displays the source link and running release version.
- [x] Translation audit across public/member/admin pages and all seven email types, with strict missing-key, catalog parity, validation/date/number and isolated production checks in CI.
- [x] Operator identity/contact details appear directly on terms and privacy pages and match the verified WetWijzer details; the official professional profile is linked.

## Beta follow-through completed

- [x] Engineering security review and fixes: address-bound email/recovery links, explicit email-confirmation POST, server password minimum, current firm-membership authorization and MFA/free-text log filtering.
- [x] Keyboard/focus/labels/landmarks/contrast/mobile fixes; all four signup locales checked at 320/800/1280px in Chrome, Firefox and Edge.
- [x] Multilingual editorial review, corrected `advocaat.be` references, and accurate Migadu Swiss-company/French-email-server disclosure.
- [x] [Support/moderation/privacy/appeals playbook](ops/support.md), [feedback intake and recording process](ops/beta-feedback.md), and [provider/data/retention register](ops/data-register.md).
- [x] Isolated encrypted restore and compatible-image rollback boot checks; authentication, private-record boundaries and no-worker/no-network isolation verified. See [operations evidence](ops/beta-ops-checks.md).
- [x] Host alert message truncation fixed and full-event/dedup behavior tested without sending. Operator confirmed the earlier synthetic alert reached Proton.
- [x] Hourly secret-free external monitoring implemented for homepage, login, readiness, generic queue health and TLS expiry; public incidents contain only sanitized probe results. Synthetic failure/recovery controls are included.
- [x] Hosted monitoring and synthetic failure/repeat/recovery acceptance passed; the owner GitHub inbox received the incident. The deployed `0.2.1` restore/rollback drill also passed, including generic queue-health 200→503→200 on the isolated copy.

## Remaining human or live evidence

- [x] Password-email inbox arrival confirmed by the operator's screenshot; the expiry-text translation issue is fixed and covered by regression tests.
- [ ] Confirm verification-email arrival and recipient-side SPF/DKIM/DMARC results for application mail.
- [ ] Operator completes administrator password setup and authenticator MFA; recovery material stays private.
- [ ] Complete a human end-to-end beta trial with verified lawyer accounts, including registration, email confirmation, posting, responding and selecting a colleague.
- [ ] Native-speaker and operator/legal sign-off on NL/FR/DE/EN terms/privacy and workflows, including operator details, retention/erasure/holds and applicable processor agreements. Public provider templates do not prove acceptance.
- [ ] External independent security review/penetration test; the engineering review is not a substitute.
- [ ] Manual screen-reader and physical Safari/iOS/Android testing, plus independent accessibility review. Automated browser checks are not WCAG certification.
- [ ] Collect actual user feedback and outcomes using the prepared process; no users or feedback are fabricated.
- [ ] Ongoing operator work: triage, moderation/privacy execution, mail quota/capacity review, backup/log/queue/TLS checks and human incident rehearsal. Migadu Micro allows 20 outgoing attempts/day across the account; no plan was changed.

## Paid launch — later, not enabled

- [ ] Belgian counsel approves the subscription/listing-fee model and professional-conduct position.
- [ ] Accountant confirms VAT treatment, invoice content, and accounting ownership.
- [ ] Peppol-capable invoicing and payment reconciliation are live and tested.
- [ ] Paid checkout, signed/idempotent webhooks, failed-payment handling, cancellation, refunds/credits, retention, and support workflows are tested.
- [ ] Pricing, billing terms, cancellation/refund policy, and product behavior match exactly before enabling paid mode.
- [ ] Confirm no lawyer-to-lawyer assignment funds pass through LawRelay.

## Public/mature launch — later

- [ ] Native legal/UX review, accessibility, independent security review, external monitoring, support playbook, moderation/appeals, incident drill, and rollback drill are complete.
- [ ] Feedback demonstrates useful activation and repeat marketplace use; publish only when the release owner accepts the go/no-go record.

## Operational references

- [Deployment](ops/deployment.md)
- [Backup and restore](ops/backup-restore.md)
- [Incident response](ops/incident-response.md)
- [Billing](ops/billing.md)
- [Security and access](ops/secrets-and-access.md)
