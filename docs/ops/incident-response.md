# Incident response

Complete the contact placeholders in the private operations system before launch. Do not put personal phone numbers or confidential provider details in this public-safe runbook.

## Roles

- Incident commander: **unassigned**
- Technical lead: **unassigned**
- Privacy/breach lead: **unassigned**
- Customer communications: **unassigned**
- Legal/accounting escalation: **unassigned**
- Backup/restore operator: **unassigned**

An incident cannot be marked operationally ready while these roles are unassigned.

## Severity

- **SEV-1:** confirmed sensitive-data exposure, account takeover at scale, destructive data loss, complete outage, payment compromise, or active exploitation.
- **SEV-2:** material feature outage, delayed queues/email, authorization weakness without confirmed exposure, failed backups, or severe performance degradation.
- **SEV-3:** limited defect with a safe workaround and no sensitive-data/security impact.

## First 15 minutes

1. Open an incident record and timestamp all actions in Europe/Brussels time.
2. Name the incident commander and establish a private response channel.
3. Classify severity and affected environments/users/data.
4. Preserve logs and evidence; do not destroy or “clean up” the only copy.
5. Contain the issue: revoke tokens, disable a feature/account, block traffic, or stop writes as appropriate.
6. Confirm backups before any destructive recovery action.
7. Decide the next update time and alert required internal roles.

## Security or privacy event

- Determine what data was accessed, by whom, for how long, and whether it was exfiltrated or altered.
- Rotate exposed credentials and invalidate active sessions.
- Preserve audit, application, provider, DNS, email, payment, and backup logs.
- Assess whether professional secrecy or client identity could be affected.
- The privacy lead must document the GDPR breach assessment. Where notification is required, the supervisory-authority clock is generally 72 hours from awareness; do not wait for a perfect investigation before escalating.
- Coordinate user, authority, bar, insurer, and law-enforcement communication with counsel.
- Do not include privileged or unnecessary personal data in incident tickets or status updates.

## Availability or data-loss event

1. Check provider status and recent deploy/migration history.
2. Stop writes when continued operation could worsen corruption.
3. Choose rollback versus restore explicitly.
4. Follow [deployment.md](deployment.md) or [backup-restore.md](backup-restore.md).
5. Validate authentication, authorization, assignment/proposal integrity, mail, jobs, and billing before reopening.

## Communication

Communicate verified facts, user impact, mitigations, and the next update time. Avoid speculation, blame, unreviewed legal conclusions, or exposing affected users. Keep public status updates separate from private evidence.

## Closure

An incident closes only after:

- Service and data integrity are verified.
- Exposed credentials/sessions are revoked.
- Required notifications and user support are complete.
- Monitoring confirms stability.
- A blameless post-incident review records timeline, root cause, contributing controls, remediation owners, and deadlines.
- High-risk remediation is tested and tracked to completion.

Run a tabletop exercise before beta and at least annually, plus a backup-restore exercise on the cadence in [backup-restore.md](backup-restore.md).
