# Migadu email setup

Migadu is the selected transactional mailbox/SMTP provider for LawRelay. Route 53 remains authoritative for `lawrelay.be`; do not delegate the domain to another nameserver set merely to configure mail.

## 1. Create the mail identities

Create and verify at least:

- `no-reply@lawrelay.be` for application delivery;
- `info@lawrelay.be` for general contact;
- `support@lawrelay.be` for user support;
- `privacy@lawrelay.be` for data-protection requests;
- `security@lawrelay.be` for security contact.

Use a dedicated strong password for the application sender and store it in the deployment secret manager. Never put it in Git, `.env` files committed to Git, screenshots, tickets, or support messages.

## 2. Copy DNS records from Migadu

Open the `lawrelay.be` domain in Migadu and copy the exact records shown by its DNS diagnostics. Add them to the existing Route 53 hosted zone. Expect MX, SPF, DKIM, and verification records; values such as DKIM selectors or verification tokens are domain/account-specific and must not be guessed from examples.

Start DMARC in monitoring mode while delivery is tested, then tighten the policy after SPF and DKIM alignment are consistently passing. Do not publish multiple SPF TXT records at the same hostname; merge authorized senders into one record if another sender is later added.

After propagation, require Migadu's domain diagnostics to pass and independently inspect a delivered message for SPF, DKIM, and DMARC alignment.

## 3. Configure Rails SMTP

Migadu supports implicit TLS on port 465 and required STARTTLS on port 587. The Hetzner production host blocks outbound 465; port 587 was tested reachable. Configure this deployment with:

```text
SMTP_ADDRESS=smtp.migadu.com
SMTP_PORT=587
SMTP_DOMAIN=lawrelay.be
SMTP_USERNAME=admin@lawrelay.be
SMTP_PASSWORD=<secret from the deployment secret manager>
SMTP_AUTHENTICATION=plain
SMTP_SSL=false
SMTP_STARTTLS=true
SMTP_OPEN_TIMEOUT=10
SMTP_READ_TIMEOUT=30
MAIL_FROM=LawRelay <no-reply@lawrelay.be>
```

The deployment loads these values from a protected environment file. Allow 30 seconds for the SMTP response after message submission; Migadu's external delivery exceeded the application's previous five-second default during launch testing.

The current `no-reply@` address is a sending identity under the `admin@` mailbox. Authenticate as `admin@` to send using that identity. The `info@` identity can sign in using the same mailbox password, but cannot send as the other identities. This distinction was verified with live SMTP delivery.

## 4. Delivery acceptance test

Before inviting any user:

1. send verification and password-reset messages to at least one external mailbox on two different providers;
2. verify links use `https://lawrelay.be` and expire as designed;
3. inspect message headers for SPF, DKIM, and DMARC pass/alignment;
4. reply to info/support/privacy addresses and confirm they reach a monitored inbox;
5. document bounce/complaint handling and the named person who monitors it;
6. record the provider's data-processing terms and subprocessor entry in the vendor register.

Application delivery remains a release blocker until this test passes. Provider ownership alone is not evidence that DNS or SMTP is working.
