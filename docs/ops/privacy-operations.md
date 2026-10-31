# Privacy review packages

Use a protected Linux server terminal after checking the requester's identity and scope. In admin, assign the request to your MFA-configured administrator and mark it **in review**. These helpers prepare review material; they do not send it, delete data, decide a hold or close a request.

Create an owned directory with mode `0700` outside the application tree and web root. Use its canonical absolute path and a new output filename:

```sh
OUTPUT=/protected/private-directory/access-123.json bin/rails 'privacy:export[123,1]'
OUTPUT=/protected/private-directory/deletion-124.json bin/rails 'privacy:erasure_inventory[124,1]'
```

The arguments are the request ID and the administrator ID. Export requires an `access_export` request; inventory requires `deletion`. Output is exclusive (no overwrite), mode `0600`; Windows is refused because this helper cannot establish private Windows ACLs. Only a metadata-only preparation event enters the audit trail. The request remains in review.

The export contains allowlisted account/profile fields, the member's own authored assignments/proposals/reports, request history, notification status, sessions and account audit timestamps/actions. Authentication secrets, audit metadata, admin resolution notes, other users' proposals, shared workspace records and historical billing records are excluded. Review authored free text before releasing it. Assess excluded and externally held personal data separately: this is not a complete automatic access-response service.

The erasure inventory counts direct references and shared workspaces without changing them. Check indirect references, other participants, the retention schedule, support mail, logs and backups before deciding what may be deleted or pseudonymised. A recorded legal, security or dispute hold pauses deletion only for the necessary records; review it every 90 days. Keep the decision privately so it can be reapplied after a restore.

## Retention and erasure

Preview scheduled cleanup first; it changes nothing:

```sh
bin/rails retention:cleanup
```

Run it only after reviewing the preview:

```sh
APPLY=true bin/rails retention:cleanup
```

Create a 90-day hold before an investigation or dispute. `TYPE` is the protected subject type, `ID` its ID, and `ACTOR_ID` the active MFA administrator:

```sh
TYPE=User ID=123 ACTOR_ID=1 REASON='Active dispute' bin/rails retention:hold
```

After identity, scope and response are reviewed, erase an assigned deletion request with:

```sh
CONFIRM=ERASE bin/rails 'privacy:erase[123,1]'
```

This requires an active MFA administrator and an assigned `in_review` member deletion request. It refuses ongoing work, holds and historical billing records. It removes profile, authentication and authored personal text where allowed, while retaining other lawyers’ work and minimal pseudonymous shared records for two years. It also completes the reviewed request. It is not a bulk account-delete tool.

Member company collection is retired. The internal `Firm` is a permission workspace; preserve its IDs, memberships and verification. `Privacy::CompanyDataCleanup` runs at application startup and daily to clear unnecessary company, invoice-recipient and KBO attribution fields. It preserves recorded holds and historical financial evidence. Preview it with `DRY_RUN=true bin/rails privacy:remove_member_company_data`; the same task without `DRY_RUN=true` applies the cleanup. Review protected records separately.

The protected deletion ledger is replayed before restored traffic or workers resume and is pruned daily after two years. A pending or incomplete ledger operation stops automatic erasure until it is resolved. Apply the retired-company cleanup before restored traffic resumes as well. Normal snapshots remain for 30 days; protected backup copies or storage versions can contain deleted data for up to about 60 days.

Review and transfer the response through the verified private channel. Keep working files outside GitHub and delete them according to the approved handling policy. Record actual execution separately before closing the request.

Rehearsal: 29 October 2026, 14 tests / 118 assertions passed on disposable synthetic records in a Linux container with no network. Checks cover secret/counterpart exclusion, request ownership, MFA-configured operator gates, file permissions/path guards, failure cleanup and non-mutating inventory. No production export, erasure or legal hold decision was performed.
