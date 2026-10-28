# LawRelay

[![CI](https://github.com/bg-ghub/lawrelay/actions/workflows/ci.yml/badge.svg)](https://github.com/bg-ghub/lawrelay/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-0.1.1-orange.svg)](CHANGELOG.md)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

LawRelay is a multilingual, lawyer-only marketplace for court cover and bounded legal assignments in Belgium. The interface supports Dutch, French, German, and English while keeping one neutral set of English URL slugs.

Current version: **0.1.1**. LawRelay follows [Semantic Versioning](https://semver.org/); releases and breaking changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## Release status

LawRelay is **pre-release**. Use local/demo data only. Do not enter client names, case facts, pleadings, privileged communications, or payment credentials until the release gates in [the master plan](docs/release-master-todo.md) are complete.

The application deliberately keeps the lawyer-to-lawyer mandate and fee outside LawRelay. Platform billing is separate from the underlying legal assignment.

## Open source

LawRelay is open-source software licensed under the [GNU Affero General Public License v3.0 or later](LICENSE). The GitHub repository is temporarily private and the application is not published or deployed while active development continues. Authorized collaborators should follow [CONTRIBUTING.md](CONTRIBUTING.md) and report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Stack

- Ruby 4.0.5 and Rails 8.1
- SQLite for local development and the initial single-node deployment
- Hotwire (Turbo and Stimulus) with import maps
- Solid Cache, Solid Queue, and Solid Cable
- Minitest, Brakeman, Bundler Audit, Importmap Audit, and RuboCop
- Kamal 2 deployment behind Kamal Proxy

## Local setup

Prerequisites:

- Ruby matching [.ruby-version](.ruby-version)
- Bundler
- SQLite 3
- libvips
- Chrome/Chromium when system tests are present

On macOS or Linux:

```sh
bin/setup --skip-server
bin/rails db:seed
bin/rails server
```

On Windows PowerShell, invoke the binstubs through Ruby:

```powershell
ruby bin/setup --skip-server
ruby bin/rails db:seed
ruby bin/rails server
```

Open `http://127.0.0.1:3000/nl`.

## Verification

Run the same checks expected by CI:

```sh
bin/rails test
bin/rails test:system
bin/rubocop
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
bin/bundler-audit check --update
bin/importmap audit
bin/rails zeitwerk:check
```

Use `ruby bin/...` for each command on Windows. The aggregate `bin/ci` runner assumes a Unix-compatible shell.

## Configuration

Never commit `.env` files, `config/master.key`, databases, uploads, API tokens, or provider credentials.

Core production variables:

| Variable | Purpose |
| --- | --- |
| `RAILS_MASTER_KEY` | Decrypts Rails credentials. |
| `APP_HOST` | Canonical public host, normally `lawrelay.be`. |
| `ADDITIONAL_HOSTS` | Comma-separated permitted aliases, normally `www.lawrelay.be`. |
| `APP_PROTOCOL` | Public URL protocol; production uses `https`. |
| `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_DOMAIN` | Transactional mail endpoint. Migadu uses `smtp.migadu.com`, port `465`, and `lawrelay.be`. |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | Transactional mail credentials. |
| `SMTP_SSL`, `SMTP_STARTTLS` | SMTP transport mode. Migadu implicit TLS uses `true` and `false` respectively. |
| `MAIL_FROM` | Verified sender identity, normally `LawRelay <no-reply@lawrelay.be>`. |
| `LAWRELAY_BILLING_ENFORCED` | Enforce posting entitlements. Production deployment defaults this to `true`. |
| `ACTIVE_STORAGE_SERVICE` | Rails storage service; defaults to `local`. |
| `CSP_REPORT_ONLY` | Set to `true` only while validating a CSP change. |
| `RAILS_LOG_LEVEL` | Production log level; defaults to `info`. |

Kamal additionally requires `LAWRELAY_SERVER_IP`, `KAMAL_IMAGE`, `KAMAL_REGISTRY_SERVER`, `KAMAL_REGISTRY_USERNAME`, `KAMAL_REGISTRY_PASSWORD`, and optionally `KAMAL_SSH_USER`.

Run Kamal from Linux or WSL. The current native Windows Ruby 4 toolchain does not bundle the `fiddle` library required by `net-ssh`, so native-Windows Kamal commands fail before reading the deployment configuration.

Production mail is disabled when `SMTP_ADDRESS` is absent. A release must not invite users until SMTP, SPF, DKIM, DMARC, bounce handling, and delivery smoke tests pass.

Migadu is the selected mail provider. Follow [the Migadu/Route 53 runbook](docs/ops/migadu-email.md); copy account-specific verification and DKIM records from Migadu rather than guessing them.

### First administrator and health checks

No administrator account is seeded in production. After the intended operator has created and verified a normal account, run the following from a protected production console or one-off release command:

```sh
EMAIL=operator@your-firm.example bin/rails lawrelay:promote_admin
```

The task refuses unknown or unverified addresses and writes an `admin.promoted` audit event. Record who ran it in the access register; the task deliberately does not claim a user performed the promotion.

Every administrator must then configure a TOTP authenticator the first time they open an administration page. The TOTP secret is encrypted at rest and is never shown again after successful confirmation; each code can only be used once. For a verified recovery process, a protected production operator can clear a named administrator's MFA setup:

```sh
EMAIL=operator@your-firm.example bin/rails lawrelay:reset_admin_mfa
```

This task removes the existing MFA enrollment, clears MFA approval from that user's active sessions, and records an `admin.mfa_reset` audit event. It must be used only after an identity check and documented in the access register.

`/up` only proves that Rails is running. `/ready` also executes a small query against the primary database and returns either `{"status":"ok"}` or an intentionally generic `503 {"status":"unavailable"}`. Point deployment readiness probes at `/ready` and monitor it externally over HTTPS after TLS is configured.

## Data and security boundaries

- Marketplace data must be available only to authenticated, verified lawyers.
- Assignment descriptions must remain generic and must not identify clients or matters.
- Court-cover language is determined by the proceeding; the language field is only used for legal assignments.
- Request logs filter credentials, contact details, search text, and free-form assignment/proposal text.
- A restrictive Content Security Policy, HTTPS redirects, HSTS, and Host-header allowlisting are enabled in production.
- Adding an external script, font, image host, analytics service, or error tracker requires an explicit CSP change and a privacy/vendor review.

## Deployment and operations

Do not run `kamal setup` until the deployment checklist, DNS, SMTP, off-host backups, monitoring, and restore drill are ready.

### Production container

`Dockerfile` builds a small, multi-stage Rails production image for Ruby 4.0.5. It runs as a non-root `rails` user and serves through Thruster on port 3000, matching the Kamal proxy configuration. Asset compilation uses a dummy build-time secret; the image never receives `config/master.key` or local environment files.

The SQLite databases and Active Storage uploads live under `/rails/storage`. Mount that path on durable storage (the Kamal configuration uses the `lawrelay_storage` volume), back it up off-host, and do not replace it during a deployment. The entrypoint runs `db:prepare` before the web process starts.

- [Hetzner provisioning](docs/ops/hetzner-provisioning.md)
- [Deployment and rollback](docs/ops/deployment.md)
- [Backup and restore](docs/ops/backup-restore.md)
- [Secrets and access](docs/ops/secrets-and-access.md)
- [Incident response](docs/ops/incident-response.md)
- [Billing operations](docs/ops/billing.md)
- [Migadu email and DNS](docs/ops/migadu-email.md)

`config/deploy.yml` intentionally requires the target host, image, registry identity, and SMTP address through environment variables so a placeholder cannot be deployed accidentally.

## Release process

1. Work in the private Git repository without committing user data, credentials, environment files, databases, uploads, or private support material.
2. Require the CI workflow on every pull request.
3. Deploy to staging and run authentication, authorization, mail, billing, and backup smoke tests.
4. Create and test an off-host backup immediately before production deployment.
5. Deploy by immutable image digest/tag.
6. Run the post-deploy checks in [deployment.md](docs/ops/deployment.md).
7. Update `VERSION` and `CHANGELOG.md`, create the matching SemVer tag (for example `v0.1.1`), and record the operator, database migration, and rollback point.

The go/no-go criteria and external legal/accounting dependencies live in [docs/release-master-todo.md](docs/release-master-todo.md).
