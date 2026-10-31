# Beta support and moderation

Owner: Gauthier Berth. `info@lawrelay.be` is the shared general contact inbox. `support@lawrelay.be`, `privacy@lawrelay.be` and `security@lawrelay.be` are active receive-only identities on that mailbox. There is no published response-time SLA.

Migadu Micro permits [20 outgoing attempts per day across the account](https://www.migadu.com/pricing/). Verification, proposal notifications, support replies and owner alerts share that budget. This infrastructure quota does not limit registration eligibility or create an invitation cap. Failed mail jobs trigger the existing owner health-alert route; if the Migadu quota is exhausted, SMTP alerts can also fail, so inspect the protected health journal. Check the failure before retrying; keep delivery smoke tests minimal.

For a bounce or complaint, inspect the delivery failure and the affected account privately. Do not blindly retry an invalid or complained-about address. If the professional address has changed, ask the lawyer to update the official directory and use LawRelay's verified email-change flow; do not replace it manually from an unverified message. Keep the provider response and decision in the private support record.

## Daily triage

1. Review the support inbox and MFA-protected administration: `/nl/admin/users`, `/nl/admin/verifications`, `/nl/admin/reports`, `/nl/admin/privacy_requests`. Administrator sign-in opens user management; the Admin navigation links the queues.
2. Prioritise suspected disclosure, takeover, urgent access loss, and failed mail. Escalate security incidents through [incident-response.md](incident-response.md).
3. Record a private reference, received date, category, owner, next action, and next review date. Keep contact details, screenshots, and correspondence outside GitHub and this repository.
4. Reply in the user's language when possible. Ask for the affected page, approximate time, browser, and a record reference; never ask for passwords, MFA codes, client names, case facts, or documents.
5. Record the outcome and tell the user what changed. Check that the issue is resolved before closing it.

## Closing support mail

Create `Support/Resolved` empty, then move the complete closed conversation there. Do not use it for open cases or bulk imports. The job never creates folders or moves mail. The local daily retention job keeps resolved threads for two years from the later of their move or last activity; it may remove linked `Sent` copies then.

Inbox, Drafts, Open, Hold, flagged mail and unrelated mail are left alone. A flag or move to Hold protects the thread again. It reads headers only, never sends mail and logs no mail content. Review its preview before enabling it; the existing invitation draft remains in Drafts.

## Verification and access

- Find the account by name, email or firm in user management. Check account access, email proof, professional verification and the primary firm separately; they are different controls.
- For a compromised or abusive member account, suspend it with a reason. This signs out its sessions and blocks sign-in; it does not alter the firm, its colleagues or published assignments. Restore only after review, with a recorded reason. Restoration does not grant professional verification.
- Use session sign-out for an active account that only needs its devices disconnected. The user can sign in again. Name/email corrections clear professional proof and sign out the affected account; a changed email must be confirmed again.
- Administrator accounts are read-only in this console. Use the audited operator recovery procedure for administrator changes; never weaken MFA to make a support action easier.
- Compare the account with the actual `advocaat.be` profile and the published professional email. A matching name alone does not prove control of that identity.
- For an expired link, use the existing resend flow. For a wrong or inaccessible directory email, ask the lawyer to correct the official listing; do not confirm a different person's account.
- A member who cannot access the listed email can use **I can’t access this email** on the verification page. They enter a working address and their password, then confirm that address. Review the request under **Email reviews** in admin, using independently published professional contact details and a recorded reason. Access remains blocked until approval; do not use the general verification action to skip this review.
- Do not disclose whether another person's email or profile is registered. Handle competing claims privately using the official profile and verified contact channel.
- Record evidence and the reason for any manual decision in the audit trail. Do not override a rejection or suspension just to clear a pending check.

## Content reports and appeals

1. Open the report, review only the material needed, and record a proportionate decision and reason. Preserve relevant evidence with restricted access.
2. Where content may expose confidential material, contain visibility promptly using a reviewed operator action; escalate suspected exposure as an incident.
3. The current report screen records review and resolution. **Resolving a report does not itself hide content or suspend an account.** Perform and verify any required remediation before marking the report resolved. Do not improvise database changes.
4. Notify the affected user through their verified contact channel. State the affected reference, action, reason, and how to appeal to `support@lawrelay.be`; omit confidential reporter information and security details.
5. For an appeal, reopen the private record, consider the user's explanation and new evidence, and record a fresh decision. Obtain a second reviewer where available; a single-operator review must be described honestly.

## Privacy requests

1. Acknowledge receipt and record the request, scope, identity check, applicable deadline, and any necessary hold. Reply without undue delay, normally within one month of receipt. If a lawful extension is needed, explain it within that first month. Escalate uncertain scope or competing obligations for review.
2. Use the signed-in request queue or a verified contact channel. Request only the identity evidence needed; avoid collecting identity documents by default.
3. Identify the relevant account, marketplace, support, audit, and backup data. Use the protected [review-package helpers](privacy-operations.md) for a scoped export or non-mutating erasure inventory. Keep other users' data out of exports and replies.
4. The admin request screen records progress; **marking a request completed does not export, correct, or delete data**. Carry out the reviewed action, verify its result, and record the action reference before completion.
5. Explain any partial fulfilment, hold, or refusal and the available complaint route. For deletion, apply the reviewed retention process and backup handling rather than promising immediate removal from every snapshot.

## Beta feedback

Use [beta-feedback.md](beta-feedback.md) for product feedback. Reports and privacy requests remain in their own queues. No billing, subscription activation, or payment collection belongs in the free-beta support flow.
