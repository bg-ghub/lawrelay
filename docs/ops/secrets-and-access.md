# Secrets and access

## Principles

- One named account per person; never share administrator credentials.
- Least privilege, short-lived credentials where supported, and MFA for every control plane.
- Separate development, staging, and production credentials.
- Store secrets in the approved password manager and inject them at runtime.
- Never place a secret in Git, a ticket, chat, screenshot, shell history, image layer, or application log.
- Review access quarterly and immediately after a role change.

## Secret inventory

Track an owner, environment, storage location, creation date, last rotation, scope, and recovery process for:

- Rails master key and encrypted credentials
- Container registry token
- Hetzner API token and SSH keys
- AWS/Route 53 access
- SMTP credentials and domain-verification records
- Backup repository and encryption keys
- Error tracking/monitoring keys
- Payment provider and webhook secrets
- Peppol/accounting integration credentials
- Support/admin recovery accounts

## Kamal

`.kamal/secrets` must resolve values from environment variables or the password manager. It must not contain literal tokens. Before every deploy, verify that:

- `RAILS_MASTER_KEY` belongs to the intended environment.
- Registry credentials can push/pull only the LawRelay image.
- SMTP credentials are scoped to the LawRelay sending domain.
- The destination host and active Hetzner context are correct.

Avoid commands that echo secret values. Clear temporary clipboard/environment values after use.

## Access matrix

Maintain a reviewed table with these roles:

- Product operator
- Production deployer
- Support/verifier
- Billing/accounting
- Privacy/security incident lead
- Read-only auditor

Document which role can access source, production shell, database, backups, user records, support records, billing, DNS, email, monitoring, and provider consoles. Support staff must not receive production-shell or backup access by default.

## Rotation

Rotate immediately after suspected exposure, staff departure, lost device, accidental logging, or third-party incident. Otherwise set provider-appropriate maximum lifetimes and review quarterly.

A rotation is complete only when the old credential is revoked, dependent services are verified, logs are checked for misuse, and the inventory is updated.

## First repository push

Before creating the private remote:

1. Confirm `config/master.key`, `.env*`, storage, logs, uploads, and database files are ignored.
2. Run a secret scanner across working files.
3. Inspect the complete staged diff.
4. If a secret was ever committed, rotate it and rewrite history before pushing; adding it to `.gitignore` is not enough.
5. Enable private visibility, MFA, branch protection, required CI, and secret scanning on the remote.

## Offboarding and recovery

Disable provider sessions and tokens before removing source access. Reassign owned alerts, billing, domains, backups, and password-manager records. Keep at least two independently recoverable administrators, but do not weaken MFA or store recovery codes with the primary password.
