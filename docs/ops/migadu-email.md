# Migadu email

Migadu is LawRelay's existing transactional mail provider. Route 53 remains authoritative for `lawrelay.be`; no new mail service is needed.

## Current setup

- `admin@lawrelay.be` authenticates to SMTP.
- `no-reply@lawrelay.be` is the application sending identity.
- `info@lawrelay.be` is the confirmed general contact inbox.
- `support@`, `privacy@` and `security@lawrelay.be` are intended contact identities; their current routing has not been independently rechecked.

Production uses Migadu on port 587 with required STARTTLS. The protected deployment environment contains the credentials; never put them in Git, screenshots, tickets or messages.

```text
SMTP_ADDRESS=smtp.migadu.com
SMTP_PORT=587
SMTP_DOMAIN=lawrelay.be
SMTP_USERNAME=admin@lawrelay.be
SMTP_AUTHENTICATION=plain
SMTP_SSL=false
SMTP_STARTTLS=true
MAIL_FROM=LawRelay <no-reply@lawrelay.be>
```

SMTP delivery has worked through the existing account. The application and internal health checks use this path.

## DNS and evidence

Migadu's domain records (MX, SPF, DKIM and verification) are account-specific. Automated DNS/token checks and internal receipt checks are recorded in the beta operations notes; do not guess or duplicate SPF records.

Recipient-side SPF, DKIM and DMARC header inspection was skipped for this beta and remains unconfirmed. It is optional follow-up evidence, not a new provider or beta gate.

## Remaining operator checks

The beta is live. When mailbox access is available:

1. Confirm replies to `info@lawrelay.be` reach the monitored inbox.
2. Check the intended support, privacy and security routing.
3. Keep provider agreement/data-processing evidence private.
4. For bounces or complaints, follow the handling note in [support.md](support.md).

Do not send a delivery campaign or add another provider for these checks.
