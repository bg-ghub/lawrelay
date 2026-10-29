# Administration

Sign in at [admin.lawrelay.be](https://admin.lawrelay.be) with the administrator password and authenticator. On first sign-in, scan the QR code with your authenticator app and enter its code.

Forgotten passwords can be reset from that sign-in page. The email goes to the existing administrator account. Resetting a password does not remove MFA.

The admin session is separate from the main website session. Cookies stay on their own host. The existing `/admin` URLs on the main website still work.

`ADMIN_HOST=admin.lawrelay.be` is set in the production environment. Route 53 points it to the existing server; Caddy provides HTTPS. Deployment reloads Caddy after the app is healthy.

For MFA recovery, use the protected SSH procedure in [secrets and access](secrets-and-access.md). Keep passwords, setup keys and recovery material private.

Release 0.5.0 validation: 294 Rails tests and 24 Chrome browser cases pass. A browser case confirms separate member/admin cookies and password/MFA sign-in. The network-isolated production image checks all four admin languages and recovery-email destinations.

Members can enable optional two-factor authentication in account settings. They scan a QR code, confirm an authenticator code, and save ten recovery codes. Recovery codes work once. Password resets keep two-factor enabled; disabling it requires the password and a valid second factor. Administrator MFA remains mandatory.
