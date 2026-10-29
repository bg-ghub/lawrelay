# Assignment notifications

| Event | Recipient |
| --- | --- |
| New response | Assignment creator |
| Selected / not selected | Respective responding lawyer |
| Response withdrawn | Assignment creator |
| Assignment selected by another firm manager | Assignment creator |
| Cancelled | Pending/selected participants and creator, excluding the person cancelling |
| Completed | Selected lawyer and creator, excluding the person completing |
| Expired at execution time | Creator and pending applicants |
| Response deadline passed | Creator; existing responses remain selectable until execution time |

Each event is committed with the action. Email uses the recipient's language and an individual address. In-app history stays available. Historical notifications are not emailed again; stale events and inactive, unverified or administrator recipients are skipped.

Missed jobs are reconciled every five minutes. Delivery failures retry with backoff; failed or overdue deliveries make the generic operations probe unhealthy. SMTP acknowledgement loss can still cause duplicate external delivery.

After fixing a failed delivery's cause, use the protected server terminal to run `bin/rails 'lawrelay:retry_notification_email[123]'`. This retries one failed record and records an audit event. Do not clear failures merely to silence monitoring. Mail-provider quotas still apply.
