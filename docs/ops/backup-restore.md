# Backup and restore

This runbook is for the initial single Linux/Docker host. It does not create a cloud bucket, credentials, or DNS record; the operator supplies those separately. Keep recovery keys and provider credentials in the password manager and root-only server files, never in this repository.

## What is protected

The `lawrelay_storage` Docker volume holds the authoritative SQLite databases and local Active Storage files. `script/ops/lawrelay-backup` creates online SQLite copies of:

- `production.sqlite3`
- `production_queue.sqlite3`
- `production_cable.sqlite3`

It runs `PRAGMA integrity_check` on each copy. It deliberately excludes `production_cache.sqlite3`, which Rails can rebuild. It archives the remaining persistent files, excluding live SQLite/WAL files and temporary backup directories. It also takes a separately locked copy of the protected erasure ledger; it is not placed inside the dated database or storage archive. The resulting snapshot is encrypted by restic before it leaves the host.

## One-time server installation

Install the required host packages using the supported package manager: Docker, `python3`, `sqlite3`, `restic`, `curl`, `util-linux` (for `flock`), and GNU tar. Do not put S3 or SMTP credentials in shell history.

Copy the reviewed scripts and units from the release checkout:

```sh
sudo install -d -m 0700 /etc/lawrelay /var/lib/lawrelay-backup/state /var/lib/lawrelay-restore-drills
sudo install -m 0750 script/ops/lawrelay-backup /usr/local/libexec/lawrelay-backup
sudo install -m 0750 script/ops/lawrelay-restore-drill /usr/local/libexec/lawrelay-restore-drill
sudo install -m 0750 script/ops/lawrelay-health /usr/local/libexec/lawrelay-health
sudo install -m 0750 script/ops/lawrelay-notify /usr/local/libexec/lawrelay-notify
sudo install -m 0644 script/ops/systemd/lawrelay-*.service script/ops/systemd/lawrelay-*.timer /etc/systemd/system/
sudo sh script/ops/prepare-retention-host
```

Create `/etc/lawrelay/backup.env` as root, mode `0600`. This is an example shape only; replace all placeholder values without printing the completed file:

```sh
RESTIC_REPOSITORY=s3:https://S3-ENDPOINT/BUCKET/lawrelay
RESTIC_PASSWORD_FILE=/etc/lawrelay/restic-password
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_DEFAULT_REGION=...
LAWRELAY_STORAGE_VOLUME=lawrelay_storage
LAWRELAY_BACKUP_WORK_ROOT=/var/lib/lawrelay-backup
```

Use a distinct, encrypted, access-restricted off-host repository, ideally in an EEA failure domain separate from the application host. Put the restic passphrase in `/etc/lawrelay/restic-password` with mode `0600`; it must not appear in `backup.env`, a command line, logs, or this repo. For an S3-compatible provider, use the documented restic endpoint/credential variables for that provider. Restrict the backup identity to the backup bucket/prefix and test recovery before relying on it.

Create `/etc/lawrelay/health.env` with mode `0600`:

```sh
LAWRELAY_BASE_URL=https://lawrelay.be
LAWRELAY_STORAGE_VOLUME=lawrelay_storage
LAWRELAY_BACKUP_STATE_DIR=/var/lib/lawrelay-backup/state
LAWRELAY_BACKUP_MAX_AGE_HOURS=26
LAWRELAY_DISK_WARN_PERCENT=85
# Optional: exact Docker container name for an additional running-state check.
# LAWRELAY_DOCKER_CONTAINER=lawrelay-web-...
```

Optional private alerts use `/etc/lawrelay/alert.env`, mode `0600`:

```sh
# LAWRELAY_ALERT_WEBHOOK_URL=https://private-alert-endpoint.example/...
# LAWRELAY_ALERT_EMAIL=operator-recovery-address@example.com
# LAWRELAY_SMTP_ENV_FILE=/home/deploy/lawrelay/production.env
# Optional; defaults to SMTP_USERNAME from the protected production env file.
# LAWRELAY_ALERT_FROM=no-reply@lawrelay.be
# Optional: suppress repeat delivery of the same message for six hours.
# LAWRELAY_ALERT_DEDUP_DIR=/var/lib/lawrelay-alerts
# LAWRELAY_ALERT_DEDUP_HOURS=6
```

The notification script always records failures to journald. Systemd `OnFailure` is the normal single notification path; set `LAWRELAY_NOTIFY_DIRECT=true` only for intentionally manual/non-systemd use. When the webhook is configured it sends only a short operational message. When `LAWRELAY_ALERT_EMAIL` is configured, it uses Python's standard library to read the mail settings and credentials from the root-readable Docker-format production env file (without sourcing/evaluating it). It honors `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_SSL`, and `SMTP_STARTTLS`: use implicit TLS for a reachable port 465, or mandatory STARTTLS for port 587 when the host blocks 465. It refuses an unencrypted or ambiguous configuration before authentication. It sends a fixed subject and synthetic operational event only—never credentials, database contents, or user data. Alert-transport failures are logged by class only (configuration, authentication, transport, or internal). A root-only SHA-256 marker is written only after a transport accepts an alert, suppressing the same message for six hours by default. Do not put SMTP passwords in a unit file or this repository.

Enable the jobs:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now lawrelay-backup.timer lawrelay-health.timer
sudo systemctl list-timers 'lawrelay-*'
```

Run and inspect the first backup before inviting users:

```sh
sudo systemctl start lawrelay-backup.service
sudo journalctl -u lawrelay-backup.service -n 100 --no-pager
sudo systemctl start lawrelay-health.service
```

The backup script holds an exclusive lock, so a second timer/manual run exits safely. Successful runs update `/var/lib/lawrelay-backup/state/last-success`; failed jobs remain visible in `systemctl` and trigger `lawrelay-failure@.service`. Restic keeps recovery snapshots for 30 days. Hetzner's separate seven daily disk backups remain unchanged.

Before installing the 30-day prune on a live repository, run a fresh backup, then review its dry run as root:

```sh
sudo /usr/local/libexec/lawrelay-backup
sudo -E restic forget --group-by host,tags --tag lawrelay --keep-within 30d --prune --dry-run
```

Do not expire current S3 objects: restic manages them. Configure the bucket separately to remove only noncurrent object versions after 30 days.

## Logs and deletion ledger

Docker writes LawRelay logs to journald. The supplied journald drop-in rotates daily and targets 30-day retention for host journal entries; because expiry happens when a file rotates, a record can remain for up to about 31 days. It is a host-wide setting, not a LawRelay-only filter. Check it with `journalctl --disk-usage` and `journalctl --verify` after installation.

`/var/lib/lawrelay-privacy` is mounted into the app solely for the protected deletion ledger. The preparation script preserves any existing ledger content, creates both `erasures.jsonl` and its stable `.lock` file with `0600` mode for the app UID, and rejects symlinks and hard links. Run it before deploying this release; Docker must not create the directory with broader permissions. It is outside the Rails tree and storage volume. The application writes approved erasure entries there; do not edit either file by hand.

Each nightly restic snapshot includes a separately locked ledger copy. This is an asynchronous off-host copy, not a zero-RPO erasure guarantee: an approved erasure after the latest successful backup may need reconciliation after replacement-host recovery.

## Restore drill

Before beta, after storage changes, and at least quarterly, run an isolated verification:

```sh
sudo systemctl start lawrelay-restore-drill.service
sudo journalctl -u lawrelay-restore-drill.service -n 100 --no-pager
```

The command restores the latest snapshot tagged `lawrelay` into a newly-created `0700` temporary directory under `/var/lib/lawrelay-restore-drills`, opens the databases read-only for integrity checks, lists the storage archive, then deletes that temporary directory. It never mounts or overwrites `lawrelay_storage`. Before returning a restored copy to service, replay the protected deletion ledger against it while writes and queue workers are still stopped.

Record the snapshot date, duration, result, data-loss window, and any gap in the private incident log.

### Isolated application and compatible-image rollback drill

The boot drill goes further than SQLite integrity checks. It restores the latest encrypted LawRelay snapshot under a new temporary directory, safely extracts storage, boots the current image, then boots an explicitly chosen compatible preceding image against the same migrated copy. It verifies four locale pages, schema/readiness, login, verified marketplace access, private-assignment ownership boundaries and the admin gate using disposable synthetic records.

The drill containers use `--network none`, publish no ports, run with constrained memory/CPU, and receive no production environment file or SMTP/AWS/SSH credentials. The actual server process unsets `SOLID_QUEUE_IN_PUMA`, including for legacy images that treat the string `false` as true; the helper separately verifies that no Solid Queue processes exist. All writes go into the disposable restore copy. It confirms that the production container ID, image, running state and start time remain unchanged. It removes only its exact generated container and temporary restore directory on exit.

Install the helper and smoke script alongside the existing restore helper:

```sh
sudo install -m 0750 script/ops/lawrelay-restore-boot-drill /usr/local/libexec/lawrelay-restore-boot-drill
sudo install -m 0640 script/ops/lawrelay-recovery-smoke.rb /usr/local/libexec/lawrelay-recovery-smoke.rb
```

Select images that already exist locally and are known to support the restored schema. Substitute the exact release tags; the helper never pulls an image or reverses a migration:

```sh
sudo systemd-run --wait --collect --pipe --unit=lawrelay-isolated-boot-drill \
  -p EnvironmentFile=/etc/lawrelay/backup.env -p PrivateTmp=true \
  --setenv=LAWRELAY_DRILL_CURRENT_IMAGE=lawrelay:0.2.0-dc4f2f19500c \
  --setenv=LAWRELAY_DRILL_ROLLBACK_IMAGE=lawrelay:0.2.0-78f08b0c2952 \
  /usr/local/libexec/lawrelay-restore-boot-drill
```

Never run `lawrelay-recovery-smoke.rb` on the production container: it intentionally creates synthetic records in a disposable copy. It refuses the production hostname, configured SMTP, or enabled queue workers. This drill proves restoration and compatibility for the tested pair only; it does not authorize an unreviewed schema downgrade or production traffic switch. Actual mail delivery, executing restored jobs, real-account MFA recovery and cross-host/provider recovery remain separate checks. Re-run after storage/schema changes and at least quarterly.

## Recovery and rollback

Do not restore into the sole production volume. For corruption or loss:

1. Declare an incident, stop writes, and preserve the original volume for evidence.
2. Select a known-good restic snapshot and calculate the expected data-loss window.
3. Restore into a new, isolated directory/volume and run SQLite integrity checks.
4. Extract the storage archive and point a compatible application release at the new volume.
5. Recover the ledger from the **latest successful** restic snapshot, even if the selected database snapshot is older. Never overwrite a current/newer host ledger with an older copy. Replay it before starting writes or queue workers.
6. Smoke-test login, permissions, assignments, attachments, mail and queues; confirm payments remain disabled before switching traffic.
7. On a replacement host, reconcile deletion requests made since the latest successful backup (up to the backup RPO) before opening traffic. Have the incident commander approve the cutover; retain the prior volume until recovery is accepted.

For a bad application release with intact data, use the deployment rollback procedure first. For failed backup configuration, disable only the affected timer with `sudo systemctl disable --now lawrelay-backup.timer`, preserve logs, fix the root-only environment file, then run a manual backup and restore drill before re-enabling it.

## Limits

The SQLite copies are transactionally consistent. The storage archive is a point-in-time file archive; avoid concurrent bulk uploads during the backup window. This small-host design is not a substitute for tested multi-region disaster recovery, separate database replication, or a legal retention policy.
