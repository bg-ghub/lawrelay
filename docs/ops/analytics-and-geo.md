# Statistics and visitor check

LawRelay runs its own self-hosted Umami 3.4 instance on the LawRelay Hetzner
server in Germany. The dashboard at
[analytics.lawrelay.be](https://analytics.lawrelay.be) has its own login,
database volume and credentials. It does not share a dataset, database or admin
account with WetWijzer.

Only anonymous public pages send cookieless pageviews, without an opt-in gate.
Queries, fragments, account details and form values are excluded. Referrers contain
only the origin. Admin, sign-in and marketplace pages are excluded. DNT/GPC and
existing opt-outs stop tracking. The footer Statistics control can turn it off or
back on. Choices last 180 days.
New visitors see a compact informational cookie banner. Its dismissal is stored
separately for 180 days and never enables or disables statistics. It is not consent.

The production environment sets `UMAMI_WEBSITE_ID`. The exact analytics origin is
allowed in CSP; automatic Umami tracking, replay and custom events are disabled.
Caddy proxies the subdomain to the private Umami container and obtains its ACME
certificate. No public dashboard share was created.

`lawrelay-analytics-retention.timer` runs on the LawRelay host daily. Its script
defaults to a dry run; `--apply` removes only this LawRelay website's records older
than 90 days in a transaction. A site/domain check prevents accidental use against
another website. Inspect the service journal after changing the Umami schema.

Deployment reads protected `umami.env` and `umami-db.env` beside `production.env`.
They are copied with mode `0600` and contain the Umami application/database
credentials, respectively; do not put those values in `production.env` or Git.
The external `lawrelay_umami_db` volume is part of LawRelay's own backup and
restore scope. GeoIP remains a separate local file refreshed from WetWijzer as
described below.

## GeoCaptcha

With `GEO_CHALLENGE_ENABLED=true`, an anonymous visitor outside Belgium must pass
the local automatic check before reading public pages. Unknown countries also get
the check. A valid member session bypasses it; account authorisation still applies.
Sign-in, registration, recovery, confirmation, health and static assets remain
reachable. No user-agent bypass is granted. The challenge includes the public
social card so link previews still have an image.

`GEOIP_DATABASE_PATH` points to the private, read-only database mount at
`/var/lib/lawrelay-geoip/GeoLite2-City.mmdb`. Country lookup happens locally and
ignores client-supplied geo headers. The app port is not published; Caddy supplies
the trusted client address.

The daily `lawrelay-geoip-sync.timer` copies the same database used by WetWijzer
over SSH. Its separate key can only read that file, from the LawRelay server's
address. The database and private key stay outside Git and container images.
The refresh preserves the last valid copy on failure and uses the existing
LawRelay failure-notification service. This mirrors WetWijzer's source database;
it does not independently update that source. MaxMind attribution is recorded in
the data register.

The local ALTCHA widget solves a ten-minute, browser-bound proof. An atomic
server-side claim prevents reuse; an unavailable claim store refuses the proof.
Success sets a signed, HttpOnly verification cookie for 24 hours. The original
local path, without query or fragment, is remembered for ten minutes.

Foreign uptime probes accept only the exact local challenge redirect and check
that its page contains the actual form/widget. Other redirects remain failures.
