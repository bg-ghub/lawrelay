# Deployment and rollback

LawRelay’s first production deployment does not use a container registry. The release script builds an immutable image on the operator workstation, transfers it directly to the Hetzner host over SSH, and starts it with Docker Compose. Kamal remains configured as a future alternative; do not mix the two methods on the same host.

## One-time host preparation

The production host is `178.105.52.108`, accessed as `deploy` using `C:\Users\Nobody\.ssh\id_ed25519_lawrelay`. It needs Docker Engine and the Compose v2 plugin:

```sh
sudo apt-get update
sudo apt-get install -y docker-compose-v2
docker compose version
```

The `deploy` user must be in the `docker` group. Docker Compose v2.30 or newer is required because the production environment is loaded in `raw` format, preserving literal characters in SMTP passwords. The deployment creates the externally named `lawrelay_storage` volume once; it contains SQLite databases and uploaded files. Never remove it as part of a deployment.

Before DNS is pointed at the server, confirm the firewall permits TCP 80 and 443. Create only an `A` record for `lawrelay.be` and `www.lawrelay.be` to `178.105.52.108`; do not publish an AAAA record unless IPv6 has been deliberately configured and tested. Caddy obtains and renews TLS certificates after public DNS resolves.

## Production environment

`script/ops/prepare-secrets.ps1` creates a private `tmp/production-secrets/production.env` from the ignored `.env.production.local`, the Rails master key, and protected generated secrets. Fill `SMTP_PASSWORD` in `.env.production.local` first. Do not commit, paste into chat, or echo either file.

The generated environment fixes the launch to `lawrelay.be`, Migadu with required STARTTLS on port 587, and the free founding beta (`LAWRELAY_RELEASE_MODE=beta`, `LAWRELAY_BILLING_ENFORCED=true`). Hetzner blocks outbound port 465 on this host. The environment contains `RAILS_MASTER_KEY` and `SECRET_KEY_BASE`; the deployment script accepts it as an input and never prints their values.

`ADMIN_HOST=admin.lawrelay.be` enables the separate [admin portal](admin.md). Its DNS A record uses the same server. Caddy serves both hosts and is reloaded after a healthy deployment.

## Deploy

Run from a clean, committed checkout in PowerShell:

```powershell
.\script\ops\prepare-secrets.ps1
.\script\ops\deploy.ps1 -ProductionEnvPath .\tmp\production-secrets\production.env
```

The script refuses a dirty tree, validates SemVer in `VERSION`, builds `lawrelay:<version>-<12-character-git-sha>`, runs the in-image release preflight, then uses SSH/SCP with `-F NUL` so local SSH configuration cannot redirect the connection. It does not change DNS or any cloud resource. A failed remote health check leaves the transferred image archive on the server for diagnosis; local temporary archives are removed.

The Rails service has no host port. Caddy is the only public container and redirects `www.lawrelay.be` to the canonical HTTPS hostname. Docker health uses `/ready` and Caddy serves `/up` and `/ready` through the application.

## Smoke tests

After deployment and DNS propagation:

- `https://lawrelay.be/up` returns 200.
- `https://lawrelay.be/ready` returns 200.
- `http://lawrelay.be` redirects to canonical HTTPS; `www` redirects to `lawrelay.be`.
- NL, FR, DE, and EN public pages work; an account verified through the official directory can sign in and complete the intended assignment flow.
- A transactional test email is delivered from the configured Migadu identity.
- `cd /home/deploy/lawrelay && docker compose --env-file release.env -f compose.production.yml ps` shows `lawrelay-app` healthy.
- The backup job and restore drill in [backup-restore.md](backup-restore.md) have passed before inviting real users.

## Rollback

Application rollback does not automatically roll back database schema or data.

Releases before `0.8.0` lack the latest MFA/session-revocation and notification-recipient checks. Test older images only in isolation; use a forward fix or a compatible recovery build that retains these protections for public traffic.

Releases before `0.7.0` cannot process the notification outbox jobs. Use a forward fix or compatible recovery image while those jobs are pending; do not downgrade and silently abandon delivery.

Releases before `0.6.0` do not enforce optional user two-factor authentication. Once any user enables it, use a forward fix or a recovery build that preserves this check; do not restore public traffic on an older image.

From `0.3.0`, account suspensions are enforced by the application. Releases before `0.3.0` ignore this status. Do not restore public traffic on an older release when accounts have been suspended: use a forward fix or a compatible recovery build that preserves suspension enforcement. Booting an older image on an isolated copy is not approval to downgrade production access controls.

1. Pause new admissions and record the incident owner and the previous image tag.
2. Restore the preceding known-good image tar (or rebuild the exact committed version) and use the same deployment procedure with that version.
3. Do not reverse a production migration automatically. Assess data compatibility and use the tested restoration process only when necessary.
4. Run the smoke tests and record the version, impact, and follow-up.
