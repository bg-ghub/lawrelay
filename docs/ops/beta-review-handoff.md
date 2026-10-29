# Remaining beta reviews

Owner: Gauthier Berth. Reviewed 29 October 2026. Paid access stays disabled.

| Review | What closes it |
| --- | --- |
| Admin access | Completed: operator password/MFA sign-in and live admin review on 29 October. Credential recovery stays in the protected server procedure. |
| Real-lawyer trial | Two verified lawyers register, confirm email, post, respond and select. Record actual outcomes privately using the [feedback form](beta-feedback.md). |
| Mail | Recipient confirms verification delivery and SPF/DKIM/DMARC results. A completed SMTP job or a DKIM signature alone is insufficient. |
| Language and legal | Native speakers and the operator/counsel review NL/FR/DE/EN signup, workflows, terms, privacy and operator details. |
| Provider agreements | Retain account-specific Hetzner DPA/appendix, applicable AWS terms/DPA and Migadu acceptance/version evidence privately; review GitHub's limited role. See the [data register](data-register.md). |
| Retention and rights | Approve account, audit, mailbox and host-journal retention; rehearse an export and reviewed erasure/hold process. Closing a privacy request does not erase records. |
| Security | An outside reviewer tests auth/recovery/MFA, directory lookup, firm boundaries and administrative actions with authorised test accounts. No real-user data or third-party directory scanning. |
| Accessibility | Human screen-reader and physical Safari/iOS/Android checks, with independent accessibility findings resolved. |
| Incident response | Operator rehearses outage, delayed mail and suspected disclosure using the [runbook](incident-response.md). Record decisions and follow-up. |

Existing evidence: [operations and recovery](beta-ops-checks.md), CI, the synthetic two-account browser journey and the internal accessibility/security checks. These support the reviews above; they do not substitute for them.

Provider references: [Hetzner DPA process](https://docs.hetzner.com/general/company-and-policy/data-protection-at-hetzner/), [Migadu privacy/DPA](https://www.migadu.com/privacy/), [GitHub customer terms](https://github.com/customer-terms). Availability of a public document does not prove account acceptance.

## Reviewer shortlist

Checked 29 October 2026. Request a small fixed-scope review and one retest where relevant.

| Area | Option | Scope and price |
| --- | --- | --- |
| Legal/privacy | [Timelex](https://www.timelex.eu/en/about-us) | Belgian IT/privacy specialists working with start-ups. Terms, directory eligibility, processor agreements and retention. Confirm coverage of lawyers’ professional rules and all four languages. Quote required. |
| Security | [NVISO](https://www.nviso.eu/en/service/penetration-testing) | Web-app assessment: signup, password recovery, MFA, firm boundaries and assignment/contact privacy. Quote required. |
| Accessibility | [AnySurfer](https://www.anysurfer.be/en/services/audits) | WCAG 2.2 A/AA sample audit and remediation review. Published initial audits: €1,250 / €2,500 / €4,000 excluding VAT by complexity; obtain the applicable quote. Ask for screen-reader and Safari/iOS/Android coverage. |
| Accessibility alternative | [Eleven Ways](https://elevenways.be/en/) | Accessibility audits and user tests with people with disabilities. Quote required. |

These are research options, not bookings. Keep real accounts and production data out of any initial quote request.
