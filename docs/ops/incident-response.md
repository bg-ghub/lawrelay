# Incident response

Keep private provider escalation contacts in the operator's password manager. Keep credentials, customer data, and recovery keys out of this repository and public status updates.

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

The [external monitor](external-monitoring.md) checks homepage, sign-in, readiness, operational queue health and TLS hourly from GitHub-hosted infrastructure. It opens one public, owner-assigned incident per outage and closes it on recovery. Issues contain only sanitized probe results; private evidence stays in the operator's incident record. Operational queue status also catches failed mail jobs when the same SMTP provider cannot send an email alert. Verify the actual GitHub notification route: issue assignment alone is not proof of email delivery. Host failures use the separately tested SMTP owner alert route.

Host alerts include the full failed unit name. The systemd template quotes its event as one argument; the notifier also joins all arguments defensively. Its six-hour duplicate suppression fingerprints the complete event, so a health failure does not suppress a separate backup failure. Run `sh script/ops/test-notify-no-send` in a Linux environment to verify this without contacting SMTP or webhook services.

For an alert:

1. Verify independently from a separate network where practical.
2. Inspect the affected unit: `sudo systemctl status lawrelay-health.service` or `lawrelay-backup.service`.
3. Read recent logs. Never paste environment files, tokens, user data, or full database output into an incident channel.
4. For a failed backup, fix the cause and run `sudo systemctl start lawrelay-backup.service`, followed by the isolated restore drill in [backup-restore.md](backup-restore.md).
5. For disk pressure, stop nonessential writes/uploads and expand capacity or remove only reviewed, non-authoritative artifacts. Do not delete a database or backup to make space.

Provider status and escalation starting points: [Hetzner status](https://status.hetzner.com/), [AWS Health](https://health.aws.amazon.com/health/status), [GitHub status](https://www.githubstatus.com/), and Migadu's authenticated admin support. Use the existing account's support route; never disclose credentials or attach unredacted databases/logs to a support request.

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
4. Validate authentication, authorization, assignment/proposal integrity, mail and jobs; confirm payments remain disabled before reopening.
5. Communicate verified impact, mitigation, and next update time. Avoid speculation or legal conclusions.

## Closure

Close only after service and data integrity are verified, required notifications/support are complete, monitoring is stable, and a blameless post-incident review has owners and deadlines. Run a tabletop before beta and annually, and a restore drill before beta and quarterly thereafter.

## Beta tabletop

Exercise these scenarios without causing an outage or sending customer messages:

| Scenario | Containment and evidence | Recovery and closure |
| --- | --- | --- |
| Full host outage | External incident; check provider status and a second network; preserve last deployment/backup information. | Restore an isolated host/copy from encrypted backup, validate application and authorization, then approve a traffic switch separately. |
| Delayed mail or failed queue job | Check queue failure/age and SMTP transport class; do not blindly delete/retry all jobs. | Fix the cause, retry the specific safe job, confirm delivery and zero unresolved failures. |
| Suspected cross-firm disclosure | Stop affected access/writes, suspend compromised accounts if needed, preserve audit/request evidence privately. | Confirm scope and privacy assessment with counsel, repair and test boundaries, coordinate any required notices, then restore access. |
| Incompatible application release | Preserve the data volume and record the deployed/previous image and schema. | Boot both images against an isolated restored copy; only switch production after compatibility and readiness pass. Never reverse a migration automatically. |

Record the owner, scenario, decision, evidence, unexercised assumptions and follow-up. An isolated restore/boot drill and synthetic alert test are useful evidence; they do not prove real provider failover, regulator communication, or customer support response time.
