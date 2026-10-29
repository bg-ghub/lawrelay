# External availability checks

The `Uptime` GitHub Actions workflow checks the public site from a GitHub-hosted runner outside Hetzner. It needs no application, SMTP, SSH or AWS credentials. The workflow token can read this repository and manage its incident issues.

At minute 17 of every hour it checks:

- the Dutch homepage returns 200, HTML, the expected locale and LawRelay content;
- the sign-in page returns 200 with an email/password form;
- `/ready` returns the exact healthy JSON contract;
- `/health/operations` returns healthy JSON with no failed jobs or due jobs waiting over 15 minutes;
- the HTTPS certificate validates for the hostname and has over 14 days remaining.

HTTP redirects, malformed responses, invalid TLS, unavailable endpoints and oversized bodies fail the check. Endpoint checks retry once before reporting failure. Probe logs contain fixed check names and pass/fail only, never response bodies or private application data.

The five-minute host check remains in place for queue failures/age, backups, disk and readiness. An hourly external check complements it: a dead host or an exhausted SMTP allowance cannot send its own email alert. The operations endpoint reveals only generic healthy/unavailable status, never job details or user data. Deploy the application version providing this endpoint before accepting or enabling the new monitor.

## Alert and recovery

A failed run opens one public incident assigned to `bg-ghub`. Incident content is limited to sanitized public-endpoint probe results; keep customer records, private contacts and server logs out of issues. Repeated identical failures leave that issue open without repeated comments. A changed set of failing checks updates it. A healthy run adds one recovery comment and closes the incident. The workflow itself is red while its probes fail.

Assignment and a failed workflow do not prove email delivery. Verify the operator's GitHub Actions/issue notification settings and actual inbox arrival separately. GitHub documents that scheduled-workflow notifications follow the workflow's actor and their preferences: [workflow notifications](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs), [notification settings](https://docs.github.com/en/subscriptions-and-notifications/how-tos/managing-github-actions-notifications).

Use the existing [incident-response runbook](incident-response.md) to investigate. Do not put account records, assignment text, credentials or raw application logs in the incident issue.

## Acceptance and safe alert test

The workflow must first exist on the default branch. Then run the actual probe:

```sh
gh workflow run uptime.yml --repo bg-ghub/lawrelay --ref main -f self_test=off
```

Exercise the failure and recovery route without contacting or changing production:

```sh
gh workflow run uptime.yml --repo bg-ghub/lawrelay --ref main -f self_test=failure
# Verify one synthetic issue, assigned to the operator. The run is intentionally red.
gh workflow run uptime.yml --repo bg-ghub/lawrelay --ref main -f self_test=failure
# Verify the same issue is reused without a duplicate comment or issue.
gh workflow run uptime.yml --repo bg-ghub/lawrelay --ref main -f self_test=recovery
# Verify the synthetic issue receives one recovery comment and is closed.
```

Synthetic tests use a separate issue marker and cannot close or update a real outage incident. Local no-network behavior checks are `python script/ops/test-external-uptime.py`.

## Limits

GitHub schedules can be delayed or dropped during high load and depend on an active actor account, the workflow remaining enabled, and available Actions budget. Scheduling at minute 17 avoids the busiest start of the hour but is not an availability guarantee. See [GitHub's schedule troubleshooting](https://docs.github.com/en/actions/how-tos/troubleshoot-workflows#scheduled-workflows-running-at-unexpected-times).

The monitor uses the existing account's Actions allowance/budget; no separate monitoring subscription is added. Watch account usage and verify recent `Uptime` runs regularly. A GitHub outage, exhausted account budget, disabled workflow or disabled notification preference can prevent an alert. This beta monitor does not provide an independent missed-heartbeat service or a 24-hour response guarantee.
