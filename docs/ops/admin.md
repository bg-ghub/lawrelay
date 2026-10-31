# Administration

Sign in at [admin.lawrelay.be](https://admin.lawrelay.be) with the administrator password and authenticator. On first sign-in, scan the QR code with your authenticator app and enter its code.

Administrator email and password cannot be changed through the website, including password-reset links. Recovery uses the protected server procedure below and retains MFA.

The admin session is separate from the main website session. Cookies stay on their own host. The existing `/admin` URLs on the main website still work.

Users lists member accounts only. Administrator identities have no user-management detail or action routes and cannot participate in the marketplace. User details show optional two-factor status. The old dated beta-access controls stay archived while the beta is free.

Email reviews lists members who cannot use their listed directory email. Compare their confirmed working address with the official profile, check their identity through independently published firm contact details, and record the check before approving. Reject when the evidence is insufficient. Approval never marks the old mailbox confirmed; changing the identity or email requires a fresh review.

`ADMIN_HOST=admin.lawrelay.be` is set in the production environment. Route 53 points it to the existing server; Caddy provides HTTPS. Deployment reloads Caddy after the app is healthy.

For MFA recovery, use the protected SSH procedure in [secrets and access](secrets-and-access.md). Keep passwords, setup keys and recovery material private.

Live review on 29 October covered Users, account details, verification, reports, privacy requests and administrator email settings through the operator's MFA-approved session. No browser errors were recorded. Moderation and account-changing actions are checked with synthetic records in automated tests. Chrome checks cover all four languages and narrow layouts; the isolated production image also checks localized pages and recovery emails.

Members can enable optional two-factor authentication in account settings. They scan a QR code, confirm an authenticator code, and save ten recovery codes. Recovery codes work once. Password resets keep two-factor enabled; disabling it requires the password and a valid second factor. Administrator MFA remains mandatory.
