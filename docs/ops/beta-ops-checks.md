# Beta operations checks — 28 October 2026

## Exercised

| Check | Evidence |
| --- | --- |
| Public external probe | Homepage, sign-in, readiness and certificate checks passed from the operator workstation outside Hetzner. |
| Alert helper behavior | Nine no-network Python checks pass, including generic operational-health JSON, duplicate suppression, destination restrictions and separation of synthetic recovery from a real incident. |
| Host alert payload | A no-send Linux test captures the complete failed-unit event, suppresses its duplicate and preserves a separate backup event. The corrected notifier and quoted systemd unit were installed; daemon-reload passed without an application restart. |
| Encrypted backup restore | Restic snapshot `9d55cfca` restored successfully; all three database integrity checks passed and storage was safely extracted into a disposable copy. |
| Current image boot | `lawrelay:0.2.0-dc4f2f19500c` booted the restored copy; schema, databases, storage, four locales, CSRF-bearing login, dashboard, verified marketplace access, own private assignment and denied unrelated assignment/admin access passed. |
| Compatible-image rollback | The preceding local image `lawrelay:0.2.0-78f08b0c2952` booted the same migrated copy and passed those checks again. No schema downgrade or production traffic switch was attempted. |
| Drill isolation | Both server processes explicitly unset the legacy queue environment flag. Process inspection confirmed no Solid Queue workers. Containers had no network, published ports or production credentials; no mail was delivered. |
| Production preservation | Container ID, image, running state and start time were identical before and after. Disposable containers and restored data were removed; production remained healthy and existing timers remained active. |

The final boot/rollback drill ran at 20:44–20:45 Europe/Brussels and completed in 47 seconds. Earlier checks found and corrected the legacy string-boolean queue flag and a process-inspection command before the final acceptance run.

## Still to verify separately

- After deploying the new `/health/operations` endpoint and merging `uptime.yml`, run the GitHub-hosted real probe and synthetic failure/repeat/recovery sequence. Record the run links and private incident ID. A local probe does not prove the scheduled runner or incident permissions work.
- Confirm the resulting incident reaches the operator's GitHub inbox and/or email. Assignment alone is not proof of delivery.
- Confirm the corrected full event in the next coordinated real alert receipt; the regression test deliberately sends no email.
- Real-account MFA/key recovery, executing restored background jobs, nonempty attachment recovery, separate-host/provider recovery and an actual production traffic cutover were not exercised.
- The incident scenarios in the runbook are a technical tabletop. Human operator response time, counsel/regulator/customer communications and provider escalation still need the operator's rehearsal.

Paid checkout, invoicing and subscriptions remain outside this exercise and disabled for the beta.
