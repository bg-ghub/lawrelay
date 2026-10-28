# Backup and restore

A backup is not complete until it is encrypted, copied off the application host, monitored, and restored successfully.

## Data inventory

The initial single-node deployment persists the `lawrelay_storage` Docker volume. It contains:

- Primary SQLite database
- Solid Cache, Queue, and Cable databases
- Local Active Storage files
- Temporary backup artifacts created during backup

The primary database and uploaded files are authoritative. Cache can be rebuilt. Queue and Cable state require a documented decision during recovery.

## Backup design

- Use SQLite's online backup API/CLI for a transactionally consistent primary database copy.
- Back up Active Storage and the consistent database copy with an encrypted tool such as restic.
- Send encrypted backups to an EEA destination in a separate provider/account or failure domain.
- Keep encryption/recovery keys in the password manager, not on the server.
- Alert on missed jobs, repository errors, unexpected backup size, and retention failures.
- Suggested starting retention: 7 daily, 4 weekly, and 12 monthly recovery points. Confirm accounting/legal retention separately.
- Do not back up cache files unless restore testing proves a need.

## Backup procedure

1. Create a timestamped staging directory on the persistent volume with restrictive permissions.
2. Use `sqlite3 ... ".backup ..."` against the live primary database.
3. Run `PRAGMA integrity_check` on the copied database and require `ok`.
4. Snapshot Active Storage files and the copied database with the encrypted backup tool.
5. Verify the remote snapshot exists and record its ID, size, duration, and source host.
6. Remove the temporary local copy only after remote verification.
7. Emit a success metric; alert when no success is received within the expected window.

Never copy a live SQLite database file with plain `cp` and assume it is consistent.

## Restore drill

Run before inviting users, after material storage changes, and at least quarterly.

1. Select a recovery point without revealing production data to unauthorized staff.
2. Restore into an isolated staging host and volume.
3. Restore the primary database and Active Storage tree.
4. Run `PRAGMA integrity_check`.
5. Boot the exact compatible application version.
6. Verify schema version, representative record counts, attachments, authentication, authorization, and background jobs.
7. Confirm sensitive data is absent from logs and monitoring.
8. Record recovery point objective achieved, recovery time, gaps, and named remediation owner.
9. Securely destroy the drill environment and restored data.

## Production recovery

1. Declare an incident and stop writes.
2. Preserve the damaged database/volume for evidence.
3. Identify the last known-good recovery point and expected data-loss window.
4. Restore into a new volume; do not overwrite the only copy.
5. Run integrity and application smoke tests.
6. Switch the application to the restored volume only after approval.
7. Notify affected users/regulators when the incident process requires it.
8. Keep a timeline of every command, decision, and custodian.

## Restore acceptance

A release is blocked until a person other than the backup implementer can follow this document and complete a successful restore without undocumented knowledge.
