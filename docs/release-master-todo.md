# LawRelay release checklist

Last audited: 28 October 2026

Current scope: an open, free founding beta for lawyers listed on advocaat.be. Registration is not invitation-only and has no cohort cap. Directory and email verification are required before marketplace access. Paid subscriptions remain disabled. Do not enter client names, case facts, pleadings, documents, or privileged material.

This is an engineering and product checklist, not legal advice. A checked item is verified; a draft or an intention is not a completed review.

## Current release status

- [x] Live at [lawrelay.be](https://lawrelay.be) over HTTPS in NL, FR, DE, and EN.
- [x] Open registration for lawyers listed in the official advocaat.be directory; no invitation or cohort limit.
- [x] Directory profile lookup, professional-email confirmation, account email verification, and suspended-account protections are implemented and tested.
- [x] Private assignments, proposals, settings, and admin routes require authentication and authorization.
- [x] Private GitHub repository; source remains unpublished to the public.
- [x] Production image deployed manually on Hetzner: revision `78f08b0c2952`.
- [x] Linux suite: 154 runs / 902 assertions; system checks: 4 / 13. Static/security scans pass.
- [x] Off-host backups and isolated restore drill pass (`9d55cfca`); nightly backups and five-minute health checks are enabled. Owner SMTP alerting was tested.
- [x] Production administrator password email completed through Migadu after configuring 10-second connection and 30-second read timeouts. The queue has no failed or pending jobs. Recipient-side inbox/header checks remain below.
- [ ] Hosted GitHub CI is not green: the budget was exhausted before jobs started and PR 9 is unmerged. Do not describe CI as passing until a real run completes.

## Verified controls

- [x] NL/FR/DE/EN locale pages, English URL slugs, language switching, metadata, sitemap, and robots rules.
- [x] Verified-lawyer and firm-scoped marketplace access, closed-assignment authorization, proposal transitions, notifications, reports, and audit events.
- [x] No client-content fields in the initial assignment flow; posting confirmation warns against client names, facts, and documents.
- [x] Admin MFA, verification queue, privacy-request queue, and moderation controls.
- [x] Free-beta billing guard: no checkout or payment request in beta; posting entitlement fails closed when billing is enforced.
- [x] Migadu identities and DNS records configured; SMTP authentication, application sender, and contact inbox tested. External recipient-side header alignment remains a monitoring item.
- [x] Production readiness endpoint, container health checks, Caddy HTTPS, canonical `www` redirect, backups, restore drill, health checks, and owner alert route.
- [x] SemVer `0.2.0`, changelog, AGPL-3.0-or-later license, secret exclusions, and repository secret scans.

## Remaining founding-beta work

- [ ] Confirm external inbox arrival and SPF/DKIM/DMARC alignment on recipient-side headers; SMTP acceptance alone does not prove inbox placement.
- [ ] Complete native-speaker legal and UX review of NL/FR/DE/EN signup, verification, marketplace, pricing, privacy, terms, and legal notice copy. Do not call template legal text approved before Belgian counsel reviews it.
- [ ] Confirm the operator's legal details, platform role, complaints/support process, privacy contact, retention, and processor/DPA register with counsel.
- [ ] Add an external uptime monitor for homepage, login, and readiness; keep an on-call owner and test alert delivery.
- [ ] Collect feedback from the first real users and record onboarding, verification, posting, response, match, and support issues.
- [ ] Arrange an independent security review/penetration test before broad public access.
- [ ] Review accessibility and browser/device coverage; fix material WCAG and keyboard/screen-reader issues.
- [ ] Keep real assignments behind authentication and continue monitoring logs, disk, queue, TLS, mail, and backup health.

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
