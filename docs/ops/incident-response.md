# Incident response

Complete private contact details and provider escalation paths before launch. Keep phone numbers, credentials, customer data, and recovery keys out of this repository and public status updates.

For the founding beta, Gauthier Berth is the incident commander, technical/recovery operator, privacy lead, and support owner. Public contact: `support@lawrelay.be`; privacy/security requests: `privacy@lawrelay.be` / `security@lawrelay.be`. Operational alerts go to the operator's private recovery mailbox, configured only on the server.

## Roles

The operating person must assign these roles for every incident; a single-person operation may hold several roles but must record that decision:

- Incident commander: coordinates decisions, timeline, and recovery approval.
- Technical lead: containment, service restoration, and evidence preservation.
- Privacy/breach lead: GDPR assessment and regulator/counsel escalation.
- Customer communications: verified user updates and support.
- Backup/restore operator: recovery-point selection and restore validation.

## Severity

- **SEV-1:** confirmed sensitive-data exposure, account takeover at scale, destructive data loss, complete outage, payment compromise, or active exploitation.
- **SEV-2:** material feature outage, delayed queues/email, authorization weakness without confirmed exposure, failed backups, or severe degradation.
- **SEV-3:** limited defect with a safe workaround and no sensitive-data/security impact.

## First 15 minutes

1. Start a private incident record and timestamp actions in Europe/Brussels time.
2. Name the incident commander, severity, affected users/data, and next update time.
3. Preserve logs and evidence. Do not remove the only database, Docker volume, backup, or provider record.
4. Contain the issue: stop writes, disable a feature/account, block traffic, or revoke credentials as appropriate.
5. Check `systemctl status lawrelay-backup.timer lawrelay-health.timer` and recent logs with `journalctl -u lawrelay-backup.service -u lawrelay-health.service -n 200 --no-pager`.
6. Confirm the last successful backup and select rollback versus restore explicitly.

## Monitoring response

The health job checks public HTTPS `/up` and `/ready`, local volume disk usage, backup age, queue database integrity, failed executions, and ready/due scheduled jobs waiting over 15 minutes every five minutes. It logs success/failure to journald; optional private alerts are configured outside git.

For an alert:

1. Verify independently from a separate network where practical.
2. Inspect the affected unit: `sudo systemctl status lawrelay-health.service` or `lawrelay-backup.service`.
3. Read recent logs. Never paste environment files, tokens, user data, or full database output into an incident channel.
4. For a failed backup, fix the cause and run `sudo systemctl start lawrelay-backup.service`, followed by the isolated restore drill in [backup-restore.md](backup-restore.md).
5. For disk pressure, stop nonessential writes/uploads and expand capacity or remove only reviewed, non-authoritative artifacts. Do not delete a database or backup to make space.

## Security or privacy event

- Determine what data was accessed, by whom, duration, and whether it was exfiltrated or altered.
- Rotate exposed credentials and invalidate active sessions.
- Preserve audit, application, provider, DNS, email, payment, and backup logs.
- Assess whether professional secrecy or client identity could be affected.
- Document the GDPR breach assessment. Where notification is required, the supervisory-authority clock is generally 72 hours from awareness; escalate promptly rather than waiting for a perfect investigation.
- Coordinate user, authority, bar, insurer, and law-enforcement communication with counsel.

## Availability or data-loss event

1. Check provider status and recent deployment/migration history.
2. Stop writes if continuing could worsen corruption.
3. Follow the recovery and rollback section in [backup-restore.md](backup-restore.md); restore into a new volume, not the only production volume.
4. Validate authentication, authorization, assignment/proposal integrity, mail, jobs, and billing before reopening.
5. Communicate verified impact, mitigation, and next update time. Avoid speculation or legal conclusions.

## Closure

Close only after service and data integrity are verified, required notifications/support are complete, monitoring is stable, and a blameless post-incident review has owners and deadlines. Run a tabletop before beta and annually, and a restore drill before beta and quarterly thereafter.
