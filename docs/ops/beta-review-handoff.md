# Remaining beta reviews

Owner: Gauthier Berth. Reviewed 29 October 2026. Paid access stays disabled.

| Review | What closes it |
| --- | --- |
| Admin access | Operator sets a password, enrols their own authenticator and confirms successful access. Keep recovery material private. |
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
