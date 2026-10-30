# Beta QA — 30 October 2026

Browser mutations used an isolated local copy with fictitious accounts and captured mail. Production uses read-only smoke checks.

## 0.12.0 additions

The full Rails suite passes (525 cases, 15,572 assertions, 17 environment-specific skips); nine focused cases also pass after the final live-page guard adjustment. All 44 Chrome cases pass (3,017 assertions), including automatic KBO preview, explicit Save, unchanged professional identity, missing/manual addresses and stale-response protection. Requests in browser tests use an offline fixture shaped like the actual public page.

Live read-only checks confirmed the public page is reachable from the production host and the parser handles a natural person and a registered company. An isolated browser saved a reviewed preview and checked source/date attribution and localized header titles in NL/FR/DE/EN. Production-image localization and internal security checks pass. No account, service subscription or external email was created.

## 0.11.0 additions

Rails: 500 tests / 15,256 assertions pass, with 17 environment-specific skips. After updating the older form expectations, all 11 affected Chrome cases pass (1,348 assertions); CI repeats the complete suite.

An isolated live browser checked directory preview without overwriting billing edits, default billing save, a different assignment invoice recipient, proposal/acceptance and invoice-contact visibility. All 32 new page/viewport checks pass across NL/FR/DE/EN at 320/1440px. The production image renders the new forms, social metadata and all email variants without sending mail. KBO is an official external lookup link, with no scraping or background requests.

## 0.10.2 baseline results

| Check | Result |
| --- | --- |
| Rails | 469 tests, 14,838 assertions; no failures/errors; 17 environment-specific skips |
| Chrome system tests | 40 cases, 2,791 assertions; no failures/errors/skips |
| Interactive browser audit | 876 page/viewport checks and 31 action checks across NL/FR/DE/EN; all 296 final-build page checks and all actions pass |
| Responsive coverage | Public pages at 320/390/768/1440px; member/admin states at 320/1440px |
| Emails | 13 templates × 4 languages, HTML and text, rendered in a disposable production image; no external delivery |
| Captured email | 14 synthetic messages have both bodies and no missing translations; verification and fresh reset links opened in the browser |

The browser audit covered public/legal pages, anonymous and pending-member gates, assignment states, settings, notifications, privacy requests, member MFA, admin users/verification/reports/privacy, and localized 404/406/422/500 responses. Fault injection was available only in the unshipped local harness.

Action checks covered proposal submission/withdrawal/decline/acceptance, contact privacy, completion/cancellation, notification pagination/read state, email confirmation, reset requests, admin suspension/restoration/session revocation, review decisions/reopening and password-plus-code sign-in.

The system suite also covers signup validation, expired links, password/email changes, MFA enrollment/recovery, profile import, unsaved-form language switching, keyboard navigation and accessibility checks.

## Fixed

- Scoped a marketing icon rule that clipped admin status badges.
- Wrapped long German privacy headings on small screens.
- Added short localized error pages with headings, recovery links and no exception details; non-HTML requests preserve the error status too.
- Removed professional credentials from public operator contacts in all four languages.

Initial findings remain in ignored local evidence at `tmp/full-browser-audit/browser-matrix.json`; affected pages passed the final-build rechecks. CI repeats the system suite and production-image rendering.

## Limits

A real second-lawyer trial and external inbox/header checks remain separate. The operator skipped recipient-side SPF/DKIM/DMARC inspection. No production test users, real email sends or new providers were used.

Current browser results use Chromium. Earlier Edge/Firefox results are historical. Physical devices and screen readers have not been tested.

See the [master checklist](../release-master-todo.md) and [operations log](beta-ops-checks.md).
