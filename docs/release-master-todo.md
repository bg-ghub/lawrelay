# LawRelay release master plan

Last audited: 28 October 2026
Current verdict: **Free founding beta selected by the operator; production deployment and acceptance checks are in progress. Paid subscriptions remain disabled.**
Current scope: verified Belgian lawyers, minimal professional assignment briefs, no client identities, case facts, or documents.
The operator explicitly selected open registration for lawyers listed on `advocaat.be`, with official-directory and email verification. Earlier references below to a small invitation-only pilot are superseded; there is no founding-cohort limit.

This document is the release source of truth. A checked item means the result was verified, not merely started. Legal and tax items must be validated by Belgian counsel/accounting professionals; this checklist is product and engineering guidance, not legal advice.

## Release gates

| Gate | Current status | Definition |
| --- | --- | --- |
| Internal demo | Ready | Seeded/local data only; no real client or matter information. |
| Invite-only free beta | Blocked externally | Account verification, private data boundaries, legal drafts, and core workflows are implemented. Operator identity, reviewed legal text, real email, production hosting, backups, monitoring, and a named support owner remain required. |
| Paid pilot | Blocked | Everything above plus approved pricing, billing, VAT/Peppol invoicing, payment terms, and failed-payment handling. |
| Public launch | Blocked | Everything above plus public operational readiness, moderation, accessibility, multilingual QA, monitoring, and a go-live/rollback drill. |

## What exists today

- [x] Rails marketplace prototype with assignment browsing, posting, and proposals.
- [x] Neutral English route vocabulary: `/assignments`, `/assignments/new`, `/assignments/:id/proposals`, and `/dashboard`.
- [x] Optional locale URL prefixes for `nl`, `fr`, `de`, and `en`.
- [x] Current marketing and marketplace screens render in NL/FR/DE/EN without missing translations.
- [x] Court replacements no longer ask for or store a language; legal assignments still require it.
- [x] Lawyer/firm accounts, email verification, password reset, expiring sessions, manual professional verification, scoped settings, and audited administrator bootstrap.
- [x] Firm-scoped assignments and proposals with participant-only closed matters, candidate acceptance/decline/withdrawal, notifications, expiry, and immutable transition audit events.
- [x] Manual invoice/Peppol-handoff and Mollie webhook foundations with explicit payment states, idempotent lifecycle processing, and enforceable posting entitlements.
- [x] Public pricing, privacy, terms, cookies, and legal-notice drafts in NL/FR/DE/EN; missing operator identity is visibly launch-blocking.
- [x] Account, professional-profile, court/practice matching, admin verification with MFA, trust-operations, readiness, and deployment/runbook foundations.
- [x] Structured court-cover and legal-task briefs, including response deadlines, scoped legal deliverables, and fixed/hourly proposals.
- [x] Automated model, controller, integration, job, mailer, service, route, locale, and browser system tests run locally without failures.
- [x] RuboCop passes after the release build.
- [x] Brakeman: no static-analysis warnings.
- [x] Bundler Audit and Importmap Audit: no known vulnerable dependencies.
- [x] `lawrelay.be` is registered and delegated to Route 53 nameservers.
- [ ] `lawrelay.eu` remains unregistered. AWS Support confirmed the account is restricted from additional domain registrations and will not lift the restriction. Failed attempts were not charged. Another registrar can be used later; this does not block the `.be` launch.
- [x] A separate Hetzner project and local `hcloud` context named `lawrelay` exist.
- [x] LawRelay remains licensed under AGPL-3.0-or-later with source stored in the private `github.com/bg-ghub/lawrelay` repository; the founding beta is SemVer `0.2.0`.
- [x] Production server provisioned in Hetzner Nuremberg: CX23, 2 shared cores, 4 GB RAM, restricted SSH, firewall, security updates, and automatic provider backups.
- [x] Migadu Micro account, domain activation, mail identities, MX/verification/SPF/DKIM/DMARC records, SMTP authentication, application-sender delivery, and contact-inbox receipt are verified.
- [ ] Public web DNS/TLS and complete deployment acceptance. Preserve all existing Migadu mail records.
- [x] Real account, authorization, notification, billing-foundation, invoice-foundation, privacy-draft, and terms-draft code exists.
- [ ] Live providers, final legal/operator data, production support, and production infrastructure are not configured.

## Decisions that block implementation

- [x] **Operator identity:** Gauthier Berth, using the public WetWijzer operator details at the user's request; see `config/operator.yml`.
- [ ] **Market boundary:** confirm that only verified Belgian lawyers/law firms can view or post assignments.
- [ ] **Data boundary:** confirm that LawRelay will not accept client names, case facts, pleadings, documents, or privileged communications in the initial release.
- [x] **Commercial model:** free founding beta now, paid subscriptions later. Payment requests and paid activation must remain disabled in beta mode.
- [x] **Admission:** open to lawyers listed on `advocaat.be`; directory and email verification replace invitation-based admission.
- [x] **Support owner:** Gauthier Berth, as the operator, is responsible for verification exceptions, moderation, privacy requests, and incidents. Paid billing is disabled.
- [ ] **Professional review:** obtain written review from Belgian counsel familiar with OVB and AVOCATS.BE rules before charging users.
- [ ] **Brand clearance:** perform and document BOIP/EUIPO trademark searches before investing in a public launch under the LawRelay name.

## Recommended money flow

LawRelay should charge for access to the software, not handle the legal fee.

1. A verified lawyer or firm subscribes to LawRelay to post assignments.
2. Verified lawyers can browse and respond without paying, which helps marketplace liquidity.
3. When two lawyers agree, they contract, invoice, and pay each other directly outside LawRelay.
4. LawRelay never holds client money, assignment fees, escrow, or payouts in the first release.

### Pricing hypothesis to validate

- Founding beta: free and invitation-only for a defined trial period.
- Launch plan: **€49/month excluding VAT per office**, cancellable monthly, with posting access and unlimited responses.
- Optional later plan: a fixed prepaid listing fee, independent of whether a match succeeds.
- Avoid percentage commissions, success fees, and outcome-dependent “handling fees” until professional-conduct counsel explicitly approves them.

At this price, one paying office should cover basic hosting/email infrastructure; ten offices would produce €490 MRR before VAT and processing costs. Price validation still requires interviews with the founding cohort.

### Collection and invoicing

- [ ] Open and verify a merchant account in the operator's legal name.
- [ ] For the first paid pilot, prefer Peppol invoices plus bank transfer; this is operationally simple and produces the correct B2B accounting trail.
- [ ] For self-service billing, integrate a hosted checkout such as Mollie and use card or SEPA for recurring collection.
- [ ] Do not assume a payment receipt is a compliant Belgian B2B invoice.
- [ ] Connect a Peppol-capable accounting/invoicing product before issuing Belgian B2B invoices.
- [ ] Store payment-provider customer/payment identifiers, never card or bank credentials.
- [ ] Implement signed, idempotent webhooks and explicit states: trialing, active, past_due, cancelled, and suspended.
- [ ] Implement invoice history, VAT details, billing email, payment-failure notices, grace period, cancellation, refunds/credits, and reconciliation.
- [ ] Test successful, failed, duplicate, delayed, and refunded transactions in provider sandbox mode.

## P0 — invite-only beta blockers

### 1. Repository and delivery foundation

- [x] Create the first reviewed Git commit and SemVer `v0.1.0` tag.
- [x] Create the private GitHub repository and push the code.
- [x] Confirm `config/master.key`, `.env*`, databases, uploads, and provider secrets are ignored and absent from history.
- [x] Run Gitleaks and targeted account/token/path scans before the first push; no findings.
- [x] Protect `main` against force-push/deletion, require version/security/lint/unit/system CI, enforce checks for administrators, and enable private vulnerability reporting plus secret push protection.
- [ ] Make the CI runner work consistently on Windows and Linux; the current aggregate `bin/ci` command assumes a Unix shell locally.
- [x] Add a SemVer-enforced `VERSION`, release tag, CI tag/version check, and changelog.
- [x] Replace the generated README with setup, environment, test, deploy, backup, and incident instructions.

### 2. Identity, verification, and authorization

- [x] Add `User`, `Firm`, `Membership`, and `LawyerProfile` records.
- [x] Add secure signup, login, logout, email verification, password reset, and expiring server sessions.
- [ ] Add persistent account lockout if operational experience shows rate limiting is insufficient.
- [x] Require TOTP MFA for platform administrators; evaluate optional MFA for lawyers later.
- [x] Record bar, bar number, firm, professional email, languages, practice areas, court preferences, admission year, and availability.
- [x] Define and implement a manual verification workflow and administrator review queue.
- [x] Store verification status, reviewer in the audit trail, decision timestamp, and review note.
- [ ] Add a dedicated verification-evidence reference and re-check date.
- [x] Require verification before a user can view assignment details, post, or respond.
- [x] Scope marketplace and account queries to the signed-in user/firm or assignment participants.
- [x] Add authorization tests proving users cannot read or mutate another firm's private records.
- [x] Replace the global dashboard with a firm-scoped dashboard and the current user's proposals/notifications.
- [x] Reveal proposal contact details only to assignment participants after acceptance.
- [x] Remove client-controlled assignment `status` and `urgent` parameters; transitions are server-authorized.
- [x] Add a least-privilege administrator role with audited promotion; no impersonation feature is present.

### 3. Safe marketplace workflow

- [x] Enforce assignment transitions: draft → open → matched → completed/cancelled/expired.
- [x] Enforce proposal transitions: pending → accepted/declined/withdrawn.
- [x] Let only the assignment creator or a firm administrator accept or decline a proposal.
- [x] Match an assignment and decline competing pending proposals inside a database lock when one proposal is accepted.
- [x] Record audit events for material transitions; database-level append-only enforcement remains a later hardening item.
- [x] Exchange professional contact details only after acceptance.
- [ ] Add cancellation reasons and a clear dispute/support path.
- [x] Expire stale assignments on a recurring job and notify the owner in-app.
- [x] Prevent duplicate proposals and multiple accepted proposals with model and database constraints.
- [ ] Add general form-level idempotency for assignment posting and other retryable mutations.
- [x] Add server-side length limits and allowlisted structured values to marketplace and trust-operation inputs.
- [x] Require an explicit “no client names, case facts, or documents” confirmation before posting; automated sensitive-text detection is intentionally not claimed.
- [x] Keep assignment details behind verified authentication and out of public sitemaps/search indexing.
- [x] Keep production seeds empty of demo users and assignments.

### 4. Email and notifications

- [x] Choose Migadu as the transactional mailbox/SMTP provider and add a deployment runbook.
- [ ] Record/review Migadu's data-processing terms and subprocessors.
- [x] Copy the account-specific Migadu MX, verification, SPF, and DKIM records into Route 53. Migadu diagnostics pass; DMARC uses its recommended quarantine policy. External header alignment still needs recipient-side confirmation.
- [x] Create `info@`, `support@`, `privacy@`, `security@`, and `no-reply@lawrelay.be` in Migadu; these route into the operator mailbox.
- [x] Replace `from@example.com` and `example.com` production sender defaults with an environment-configured LawRelay sender.
- [x] Build and locally test email verification, password reset, new proposal, accepted/declined, and cancellation mailers; provider delivery is not live.
- [ ] Add billing and account-security notice mailers before the paid pilot.
- [ ] Process bounces and complaints; suppress repeatedly failing recipients.
- [ ] Add notification preferences without allowing users to disable essential service/security messages.
- [x] Align requester/candidate notification copy with the implemented in-app and email notifications.

### 5. Legal pages and commercial disclosures

- [x] Implement pricing-page drafts in NL/FR/DE/EN with price excluding VAT, billing interval, included features, trial, cancellation, and payment timing.
- [ ] Publish operator/legal-notice details permanently in the footer or a clearly linked page.
- [x] Implement terms-of-service drafts in NL/FR/DE/EN.
- [x] Implement privacy-notice drafts in NL/FR/DE/EN.
- [x] Implement a cookie notice limited to the application's current first-party use.
- [x] Add legal links beside signup and sensitive-content posting confirmations.
- [x] Record terms/privacy version and acceptance timestamp per account.
- [ ] Terms must cover eligibility, verification, platform role, professional responsibility, conflicts, confidentiality, prohibited content, fees/VAT, cancellations, suspension, moderation, liability, complaints, governing law, and changes.
- [ ] State clearly that LawRelay is not a law firm, employer, client, escrow service, or party to the lawyer-to-lawyer engagement.
- [ ] State that each lawyer remains responsible for conflicts, authority to delegate, professional secrecy, deadlines, court rules, insurance, fees, and the underlying mandate.
- [ ] Have final text reviewed by Belgian counsel; do not publish template legal text as “approved.”

### 6. Privacy, confidentiality, and data governance

- [ ] Map every personal-data field, purpose, legal basis, recipient, processor, location, and retention period.
- [ ] Decide and document controller/processor roles for platform data and user-posted content.
- [ ] Create a record of processing activities and a subprocessor register.
- [ ] Sign DPAs with hosting, email, error tracking, payments, analytics, support, and backup vendors.
- [ ] Keep production data in the EEA unless a reviewed transfer mechanism is in place.
- [ ] Define retention and automatic deletion for unverified accounts, expired assignments, proposals, audit logs, support records, and billing records.
- [x] Implement authenticated access/export, correction, objection, restriction, and deletion request intake and an audited administrator queue.
- [ ] Implement automated data export/deletion execution after the retention and identity-verification policy is approved.
- [ ] Keep legally required billing records separate from product-data deletion.
- [ ] Add a privacy/security contact process and response log.
- [ ] Complete a DPIA screening and conduct a DPIA if the final processing risk requires it.
- [ ] Ensure application logs never contain tokens, full emails, client information, free-text matter details, or payment data.

### 7. Abuse, moderation, and platform duties

- [x] Add per-IP or per-account rate limiting to login, signup, verification resend, assignment, proposal, password reset, billing, report, and privacy-request endpoints.
- [ ] Add bot/spam controls that preserve accessibility.
- [x] Add assignment-report flows with reason codes and self-report prevention.
- [x] Add an audited administrator moderation queue with review, resolution, and dismissal states.
- [ ] Add the launch policy and UI for appeals/complaints and user-level reports.
- [ ] Define prohibited content and repeat-abuser rules.
- [ ] Determine with counsel whether LawRelay is a DSA hosting service/online platform and implement the applicable contact, notice-and-action, statement-of-reasons, terms, and reporting duties.
- [ ] Define law-enforcement/legal-request handling and never disclose privileged information casually.

### 8. Production infrastructure

- [x] Create the small Hetzner CX23 production server in Nuremberg with provider backups enabled.
- [ ] Create a separate staging environment and separate credentials/data.
- [x] Replace placeholder deploy targets with required environment variables so accidental placeholder deployment fails.
- [x] Add and validate a multi-stage non-root production container image compatible with Kamal/Thruster; local keys and runtime data are excluded from its build context.
- [ ] Use a private container registry and pinned images.
- [ ] Harden SSH, use a non-root deploy user, disable password login, restrict the firewall, and enable security updates.
- [ ] Prefer managed or separately backed-up PostgreSQL for production; if SQLite is retained for a tiny beta, document concurrency limits and prove backup/restore.
- [ ] Encrypt backups and store copies off-host in a separate failure domain.
- [ ] Automate database, Active Storage, and configuration backups with retention and failure alerts.
- [ ] Perform and document a full restore drill before beta.
- [ ] Configure `lawrelay.be` and `www.lawrelay.be` DNS, redirect one canonical host, and enable TLS.
- [x] Configure `assume_ssl`, `force_ssl`, HSTS, secure cookies, and production host allowlisting; live TLS validation remains external.
- [x] Enforce and test a restrictive Content Security Policy with an explicit report-only override.
- [x] Add secure response headers, filtered parameters, expiring sessions, and secure production cookies.
- [x] Add an application-level database readiness check in addition to process liveness.
- [ ] Extend readiness checks to queue and storage once the production services are selected.
- [x] Document migration safety, deployment smoke tests, and rollback procedures.

### 9. Monitoring, support, and incident readiness

- [ ] Add error tracking with personal-data scrubbing.
- [ ] Add uptime checks from outside Hetzner for homepage, login, and readiness endpoints.
- [ ] Monitor CPU, memory, disk, database size/locks, queue age/failures, email failures, TLS expiry, backup success, and payment webhooks.
- [ ] Route alerts to a named on-call owner and test the route.
- [ ] Define log retention and access controls.
- [ ] Write incident severity levels, containment steps, communications templates, and recovery ownership.
- [ ] Add a GDPR breach-assessment workflow capable of meeting the 72-hour notification window when notification is required.
- [ ] Publish a support contact and target response times.
- [x] Create administrator tools for account verification, content reports, and privacy requests.
- [ ] Add dedicated suspension and billing-support tooling before the paid pilot.

## P0 — paid-pilot blockers

- [ ] Counsel approves the platform subscription/listing-fee structure and confirms it is not prohibited fee-sharing or client introduction compensation.
- [ ] Accountant confirms VAT treatment and invoice content.
- [ ] Peppol-capable invoicing is live; Belgian structured B2B e-invoicing has applied since 1 January 2026.
- [ ] Pricing page, billing terms, and cancellation/refund policy match the actual product behavior.
- [x] Billing entitlements fail closed in production and can prevent unpaid firms from posting; local development and tests remain unenforced unless `LAWRELAY_BILLING_ENFORCED=true` is set.
- [ ] Payment and invoice reconciliation has a named operational owner.
- [ ] Sandbox and live low-value payment tests pass.
- [ ] Refund/credit, failed-payment, cancellation, and account-closure tests pass.
- [ ] No lawyer-to-lawyer assignment funds pass through LawRelay.

## P1 — public-launch requirements

### Product and language

- [x] Implement NL/FR/DE/EN translations for the current UI, transactional mail, validation errors, legal drafts, pricing, and metadata.
- [x] Use English slugs consistently beneath locale prefixes, for example `/fr/assignments`.
- [x] Add a visible language switcher that preserves the current destination.
- [x] Persist account language and fall back safely for emails/background jobs.
- [x] Add `hreflang`, canonical tags, translated titles/descriptions, sitemap, and robots rules.
- [ ] Perform native-speaker legal and UX review; machine-quality translation is not enough for terms or professional workflows.
- [x] Add profiles, practice areas, court coverage, availability, and matching preferences with restrained dashboard suggestions.
- [ ] Add saved searches and useful, restrained matching notifications.

### Accessibility and quality

- [ ] Meet WCAG 2.2 AA as the working target and document any applicable EAA microenterprise assessment.
- [ ] Test full keyboard operation, focus order, screen-reader labels, error summaries, contrast, zoom, reduced motion, and language declarations.
- [x] Add browser system tests for locale-preserving login, court/legal form behavior, safe posting, and closed-assignment authorization.
- [ ] Extend browser coverage to signup, verification, proposal acceptance, billing, and cancellation.
- [ ] Add payment webhook, mailer, job, policy, request, and privacy-retention tests.
- [ ] Test current Chrome, Edge, Firefox, and Safari plus representative iOS/Android sizes.
- [ ] Test slow networks, duplicate clicks, expired sessions, provider outages, and queue retries.
- [ ] Set performance budgets and test the public landing page and authenticated board.
- [ ] Arrange an independent security review/penetration test before broad public access.

### Go-to-market and operations

- [ ] Interview at least 10 target lawyers and validate problem, willingness to pay, and the proposed €49 price.
- [ ] Run a moderated pilot with 5–15 verified firms and record activation, time-to-first-post, response rate, match rate, and repeat usage.
- [ ] Define a north-star metric: completed verified matches per active firm per month.
- [ ] Keep real assignments behind authentication; use the public site for explanation, trust, pricing, and signup.
- [ ] Use privacy-friendly, consent-aware analytics or launch without non-essential analytics.
- [ ] Prepare onboarding, verification, support, billing, moderation, and offboarding playbooks.
- [ ] Prepare a status page and incident communications channel.
- [ ] Confirm insurance coverage appropriate to the platform and cyber/privacy risk.

## P2 — only after the core marketplace works

- [ ] Team accounts, multiple offices, roles, consolidated billing, and usage quotas.
- [ ] Calendar integration and structured availability.
- [ ] Paid boosts only after counsel approves the model and ranking disclosure is clear.
- [ ] Reviews/ratings only with authenticity, dispute, and moderation rules.
- [ ] Secure messaging only after retention, encryption, access, moderation, and professional-secrecy design.
- [ ] File exchange only after a separate threat model, malware scanning, encryption, retention, access logging, and counsel review.
- [ ] Automated bar-status re-verification.
- [ ] Advanced matching, reporting, and accounting integrations.
- [ ] Formal security programme, annual penetration testing, and cyber-insurance review.

## Go/no-go acceptance tests

### Invite-only free beta

- [ ] Only invited, email-verified, manually verified lawyers can access marketplace data.
- [ ] Cross-firm authorization tests pass.
- [ ] No client identity, case facts, or documents are accepted or exposed.
- [ ] Privacy notice, beta terms, operator identity, support, and reporting are live.
- [ ] Production TLS, email, backups, monitoring, alerts, and restore drill pass.
- [ ] End-to-end assignment → proposal → acceptance → notification works.

### Paid pilot

- [ ] Every free-beta acceptance test still passes.
- [ ] Counsel/accountant sign off on commercial structure, VAT, terms, and invoice flow.
- [ ] Peppol invoice and payment reconciliation work end to end.
- [ ] Billing failure, cancellation, credit/refund, and data-retention behavior is tested.

### Public launch

- [ ] Every paid-pilot acceptance test still passes.
- [ ] NL/FR/DE/EN content has native-speaker review.
- [ ] Accessibility, browser/device, performance, security, moderation, and incident drills pass.
- [ ] Pilot metrics show repeat use and enough marketplace liquidity to avoid an empty public launch.
- [ ] A named release owner signs the go/no-go record and rollback criteria.

## Authoritative references

- [FOD Economie — required company identification on business websites](https://economie.fgov.be/nl/themas/online/elektronische-handel/verkoop-internet/bedrijfswebsite-en-accounts-op)
- [Belgian Data Protection Authority — cookies and tracking](https://www.gegevensbeschermingsautoriteit.be/professioneel/thema-s/cookies)
- [GDPR — Regulation (EU) 2016/679](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:32016R0679)
- [European Data Protection Board — personal data breach guidance](https://www.edpb.europa.eu/sme/assess-the-risks/data-breaches_en)
- [Digital Services Act — Regulation (EU) 2022/2065](https://eur-lex.europa.eu/eli/reg/2022/2065)
- [OVB Advice 720 — digital legal platforms and professional duties](https://www.ordevanvlaamsebalies.be/nl/deontologie-adviezen/advies-720)
- [Belgian e-invoicing FAQ — mandatory structured B2B invoices from 2026](https://einvoice.belgium.be/en/FAQ/general-questions-b2b)
- [European Commission — European Accessibility Act](https://commission.europa.eu/strategy-and-policy/policies/justice-and-fundamental-rights/disability/european-accessibility-act-eaa_en)
- [Mollie Belgium — current payment-method pricing](https://www.mollie.com/be-fr/pricing)
- [Mollie Docs — Bancontact capabilities](https://docs.mollie.com/docs/bancontact)
