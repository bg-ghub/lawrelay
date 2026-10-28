# Deployment and rollback

This runbook assumes a private registry, a hardened Hetzner host, Kamal 2, working DNS, SMTP, monitoring, and an off-host backup.

Run Kamal from Linux or WSL. Native Windows Ruby 4 currently lacks the `fiddle` dependency used by `net-ssh` in this workspace.

## Required environment

Set these in the operator shell or approved secret manager, never in Git:

```text
APP_HOST
ADDITIONAL_HOSTS
LAWRELAY_SERVER_IP
KAMAL_IMAGE
KAMAL_REGISTRY_SERVER
KAMAL_REGISTRY_USERNAME
KAMAL_REGISTRY_PASSWORD
KAMAL_SSH_USER
RAILS_MASTER_KEY
SMTP_ADDRESS
SMTP_PORT
SMTP_DOMAIN
SMTP_USERNAME
SMTP_PASSWORD
```

Make `.kamal/secrets` resolve secret values from the approved password manager or environment. Do not paste raw credentials into that file.

## First staging setup

1. Confirm the Git working tree and intended commit/tag.
2. Run the complete local/CI suite.
3. Verify the active Hetzner project and the exact destination IP.
4. Verify DNS for the staging hostname.
5. Inspect rendered configuration with `bin/kamal config`.
6. Create an off-host backup destination and test credentials.
7. Run `bin/kamal setup`.
8. Confirm TLS, Host-header filtering, `/up` process liveness, and `/ready` database readiness.
9. Run every post-deploy smoke test below.
10. Create and restore a staging backup before approving production.

## Routine deployment

1. Announce the change owner, expected impact, and rollback point.
2. Check monitoring and confirm there is no active incident.
3. Review migrations for locks, irreversible changes, and backward compatibility.
4. Run:
   - `bin/rails test`
   - `bin/rubocop`
   - `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error`
   - `bin/bundler-audit check --update`
   - `bin/importmap audit`
5. Create and verify an off-host pre-deploy backup.
6. Build and publish an immutable image tag.
7. Inspect `bin/kamal config` and confirm host, image, registry, and environment.
8. Run `bin/kamal deploy`.
9. Watch `bin/kamal logs` and external uptime checks.
10. Record commit, image tag/digest, migration version, operator, start/end time, and result.

## Post-deploy smoke tests

- `https://lawrelay.be/up` returns 200 and `https://lawrelay.be/ready` returns `{"status":"ok"}`.
- HTTP redirects to HTTPS and the canonical host.
- NL/FR/DE/EN landing, pricing, terms, privacy, login, and assignment pages render.
- A test account can sign in and sign out.
- Cross-firm authorization checks still fail closed.
- Assignment creation, proposal, acceptance/decline, and notification paths work.
- A transactional test email arrives and links to the canonical host.
- Queued jobs are processed without retries.
- Error tracking receives a scrubbed test event.
- Backup and monitoring dashboards remain green.
- No page contains `translation missing` or demo records in production.

## Rollback

Application rollback and database rollback are separate decisions.

1. Stop further deploys and name the incident commander.
2. If code is faulty but the schema remains backward-compatible, use the prior known-good image according to `bin/kamal help rollback`.
3. Never reverse a production migration automatically. Review data loss and compatibility first.
4. If data restoration is required, follow [backup-restore.md](backup-restore.md) and preserve the failed database for investigation.
5. Re-run the complete smoke test after rollback.
6. Record the trigger, version restored, data action, customer impact, and follow-up owner.

## Deployment stop conditions

Stop and investigate if any of the following occurs:

- Backup or restore verification fails.
- The target host, registry, image, or domain is unexpected.
- A migration is irreversible without an approved recovery plan.
- Health checks, authentication, authorization, mail, queue, or billing smoke tests fail.
- Error rate, latency, memory, disk, or queue age crosses its alert threshold.
