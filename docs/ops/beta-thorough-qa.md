# Beta checks — 29 October 2026

Release 0.4.7 fixes issues found during the beta review:

- Expired directory links return safely; configured admin MFA cannot restart initial setup.
- Response cutoffs and hearing dates are enforced. Invalid forms show errors without crashing.
- Money inputs reject invalid/overflowing values and preserve cents and zero.
- Past matched assignments remain reachable for completion.
- Turbo's progress styling works with CSP. The broken professional-rules link is corrected.
- Beta pricing and billing screens redirect; pricing material is archived. Other-product links remain.

## Evidence

| Check | Result |
| --- | --- |
| Rails suite | 278 tests, 10,436 assertions; no failures or errors. |
| Production image | Public/member/admin pages in four languages and seven emails in HTML/text pass with a disposable database, no network or mail delivery. |
| Public UI audit | 128 page/viewport checks, 32 axe scans and 16 keyboard checks at 320/390/800/1440px. No overflow or missing translations. The detected CSP issue is fixed and browser-tested. Logo contrast is exempt as a logotype. |
| Static/dependency checks | RuboCop and Brakeman pass; Ruby/import-map dependency audits report no vulnerabilities. |
| Live operations | Healthy image, TLS and readiness; SQLite integrity passes, queues empty, backup/health timers successful. Fresh backup passed before deployment. |

Browser checks cover Chrome and Edge (17 cases each) and Firefox (14 cases). Three viewport checks use Chromium-specific controls. Hosted CI repeats Chrome and the production-image checks; deployment is checked separately.

## Limits

Browser signup, directory responses and mail are synthetic. A real two-lawyer trial, recipient-side mail authentication headers, operator MFA enrollment, physical Safari/iOS/Android and screen-reader checks, and independent legal/security/accessibility reviews remain on the [master checklist](../release-master-todo.md).
