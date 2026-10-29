# Privacy review packages

Use a protected Linux server terminal after checking the requester's identity and scope. In admin, assign the request to your MFA-configured administrator and mark it **in review**. These helpers prepare review material; they do not send it, delete data, decide a hold or close a request.

Create an owned directory with mode `0700` outside the application tree and web root. Use its canonical absolute path and a new output filename:

```sh
OUTPUT=/protected/private-directory/access-123.json bin/rails 'privacy:export[123,1]'
OUTPUT=/protected/private-directory/deletion-124.json bin/rails 'privacy:erasure_inventory[124,1]'
```

The arguments are the request ID and the administrator ID. Export requires an `access_export` request; inventory requires `deletion`. Output is exclusive (no overwrite), mode `0600`; Windows is refused because this helper cannot establish private Windows ACLs. Only a metadata-only preparation event enters the audit trail. The request remains in review.

The export contains allowlisted account/profile fields, the member's own authored assignments/proposals/reports, request history, notification status, sessions and account audit timestamps/actions. Authentication secrets, audit metadata, admin resolution notes, other users' proposals and shared firm/billing records are excluded. Review authored free text before releasing it. Assess excluded and externally held personal data separately: this is not a complete automatic access-response service.

The erasure inventory counts direct references and shared firms without changing them. It always records the hold decision as **not assessed**. Check indirect references, other participants, retention, complaints/holds, support mail, logs and backups before deciding what may be deleted or anonymised. Keep an approved erasure record privately so it can be reapplied after a restore.

Review and transfer the response through the verified private channel. Keep working files outside GitHub and delete them according to the approved handling policy. Record actual execution separately before closing the request.

Rehearsal: 29 October 2026, 14 tests / 118 assertions passed on disposable synthetic records in a Linux container with no network. Checks cover secret/counterpart exclusion, request ownership, MFA-configured operator gates, file permissions/path guards, failure cleanup and non-mutating inventory. No production export, erasure or legal hold decision was performed.
