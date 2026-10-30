# Beta QA — 30 October 2026

Release 0.10.2. Browser mutations used an isolated local copy with fictitious accounts and captured mail. Production browser checks were read-only.

## Results

| Check | Result |
| --- | --- |
| Rails | 468 tests, 14,824 assertions; no failures/errors; 17 environment-specific skips |
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
- Added short localized error pages with headings, recovery links and no exception details.
- Removed professional credentials from public operator contacts in all four languages.

Initial findings remain in ignored local evidence at `tmp/full-browser-audit/browser-matrix.json`; affected pages passed the final-build rechecks. CI repeats the system suite and production-image rendering.

## Limits

A real second-lawyer trial and external inbox/header checks remain separate. The operator skipped recipient-side SPF/DKIM/DMARC inspection. No production test users, real email sends or new providers were used.

Current browser results use Chromium. Earlier Edge/Firefox results are historical. Physical devices and screen readers have not been tested.

See the [master checklist](../release-master-todo.md) and [operations log](beta-ops-checks.md).
