# Beta operations checks

## 30 October 2026 — 0.10.2 browser audit

Completed 876 page/viewport checks and 31 interactive actions in NL/FR/DE/EN, using a separate local test copy and read-only production pages. Fixed clipped admin badges, long German privacy headings and untranslated error pages. All 296 final-build rechecks and all actions passed. Public operator contacts now omit professional credentials.

Rails: 468 tests / 14,824 assertions, no failures/errors, 17 environment-specific skips. Chrome: 40 system cases / 2,791 assertions, no failures/errors/skips. Production-image rendering checks 13 mail templates in four languages, HTML and text, without delivery. Captured local verification/reset links also opened correctly. [Detailed scope](beta-thorough-qa.md).

No real administrator credentials/MFA, production users or outreach drafts were changed. Real second-lawyer feedback and recipient-side email evidence remain separate.

## 30 October 2026 — synthetic three-lawyer trial

Created three clearly labelled fictitious profiles in a fresh local copy of the release image. The real directory parser used local HTML fixtures; normal registration and email-confirmation paths activated the accounts. The app has its own Docker volume, no production credentials, an internal network and a loopback-only browser proxy. Mail is captured locally and rejects non-test recipients. No production users or official directory records were changed.

Manual browser checks passed for a blank indicative price, two competing proposals, acceptance, automatic non-selection, contact privacy and completion notifications. That completed scenario captured eight local messages, all to test addresses; its five workflow notifications were marked sent to that local capture. A separate open test assignment with two proposals remains for operator testing.

The enhanced automated journey also checks separate login/directory mailbox confirmations and cancellation. The complete local browser suite passed: 32 cases, 1,507 assertions, no failures/errors/skips; RuboCop passed for the changed test. These are synthetic results, not real participant feedback or proof of external inbox delivery.

## 30 October 2026 — private provider archive

Collected the existing Hetzner account DPA with Appendix 1 and Migadu's current account/subscription record and receipt text copy. These join the AWS/GitHub agreements and available account context in the restricted archive outside Git. Document hashes, PDF readability and owner/SYSTEM-only access checks passed. Only this status is public; no account documents or identifiers were added to the repository. No new agreement or account setting was submitted.

## 29 October 2026 — 0.10.1

Terms/privacy read-through checked operator contacts and the implemented verification, visibility, retention and moderation flows. All four notices now clarify recipients, retention exceptions, provider transfers and rights requests. Signup distinguishes accepting terms from reading the notice; both versions are recorded. The platform-role wording is shorter. Account-specific provider-agreement evidence remains separate.

The registration, operator-contact and localized-page checks passed: 17 cases, 1,089 assertions. Hosted CI and live release checks are recorded with the release.

## 29 October 2026 — 0.10.0

Migadu admin checks confirmed that support/privacy/security are active receive-only identities of the existing shared mailbox used by info@lawrelay.be. Three individual delivery tests arrived in INBOX. The one invitation draft was untouched. No mail configuration or provider changes were needed.

Resolved support-mail cleanup uses the existing Migadu IMAP account and host timer. It reads headers only, starts a two-year closure clock, protects open/held/flagged/draft mail, and uses exact UID deletion only for eligible resolved threads and linked Sent copies. Failures or a missed daily run use the existing health-alert path. Closure metadata joins the encrypted backup.

Thirteen offline mailbox cases and four host-health cases pass on Linux without network access. Checks cover scope, malformed headers/state, fresh replies, changes before deletion, failure recovery and secret-free output. A live read-only preview succeeded across nine folders with zero eligible messages. New support folders were empty; no existing mail was moved or deleted and the invitation draft was preserved. Final installation and release checks are recorded with the release.

## 29 October 2026 — 0.9.0

Retention defaults: abandoned email-unconfirmed registrations 30 days, terminal notifications 90 days, closed work/requests/support 2 years, audit records 1 year, technical logs up to 31 days, encrypted backups 30 days. Recorded holds and unresolved work/requests protect relevant records. Mailbox cleanup remains manual.

Internal checks include shared-firm preservation, erasure authorisation, stale forms, two-year cleanup, bounded holds and commit-safe ledger replay. The local Rails suite passed 463 cases (17 platform-specific skips); the Linux-focused suite passed 36 cases / 167 assertions with one Windows-only skip. Subsequent focused cases also pass. RuboCop and Brakeman report no findings. No real account was erased.

S3 noncurrent-version retention was changed from 90 to 30 days, preserving current objects and the existing incomplete-upload rule. A fresh pre-release backup succeeded; the 30-day restic preview kept all three available snapshots. Protected ledger/lock permissions and local journald retention were prepared on the existing host. Final deployment and hosted CI results are recorded with the release.

## 29 October 2026 — 0.8.7

Directory-confirmation enqueue failures now preserve the matched profile and retry the handoff up to three times. Pending verification distinguishes mail waiting to be sent from mail accepted by SMTP; this is not proof of inbox arrival.

Validation: 431 Rails cases pass locally with eight POSIX-only skips. Eight focused delivery/status cases pass with 344 assertions, including retry recovery/exhaustion, sanitized errors and both mail states in all four languages. RuboCop and the nine no-send uptime tests pass.

Read-only production checks found healthy HTTPS/readiness/operations, database integrity, backup/health timers and notification delivery. No failed jobs; disk usage was 11%. The existing Migadu admin session was expired, so support/privacy/security alias routing remains unconfirmed. No new provider was added and no test email was sent.

## 29 October 2026 — 0.8.6

Signup and saved corrections now recover from partial/failed enqueue attempts with retry guidance. Verification mail and temporary directory failures retry up to three times. Missing profile pages are permanent failures; safe directory reasons explain how to recover. Privacy-admin completion records a manual outcome without implying automatic data actions.

Validation: 428 Rails cases / 14,497 assertions pass on Windows (8 POSIX-only skips); 32 Chrome cases / 1,448 assertions pass. RuboCop and Brakeman pass. The isolated production-language check covers pending/error/resend screens and mail in all four languages without external delivery.

Fresh backup `472a6292` at 19:16 Europe/Brussels restored and booted in 58 seconds. Candidate 0.8.6 exercised its serialized verification-email job, assignment notifications and privacy helpers with the test adapter and no network. The 0.8.5 compatibility boot also passed after the synthetic new job was consumed; it cannot handle pending new verification jobs. Production identity/start time stayed unchanged, and temporary data was removed.

Live pre-release checks passed public HTTPS, official profile lookup, database integrity, queues, backup/health timers and disk capacity. The checklist now focuses on the real two-lawyer trial and owner decisions; paid outside reviews are optional future work.

## 29 October 2026 — 0.8.1

Indicative assignment rates are optional in all four languages. Blank values remain distinct from zero and display "To be agreed" (localized). Posting without a rate passes in Chrome, Edge and Firefox; 27 focused integration cases / 263 assertions pass.

A bounded Edge check of eight board/detail pages at actual 320px passes 169 assertions. The German unspecified-rate label now wraps with spacing instead of touching its heading.

Additional engine checks: Edge 156 passes the full 32-case suite / 1,446 assertions. Firefox 159 passes 19 cases / 354 assertions covering registration, both confirmations, matching, recovery, email changes, language guards, private-assignment boundaries and admin MFA/actions. Chromium-specific viewport cases are excluded from Firefox. Each engine also passes the latest blank-rate posting case separately (5 assertions). All data/mail are synthetic and use isolated databases; physical Safari/iOS/Android and screen-reader evidence remain open.

## 29 October 2026 — 0.8.0

| Check | Result |
| --- | --- |
| Security review | Fixed pre-MFA homepage assignment visibility, session-revocation races during MFA, and notification delivery after professional verification changes. Focused regressions pass; this is an internal review. |
| Application/browser checks | 397 Rails cases / 13,820 assertions pass; 8 POSIX-only cases skip on Windows. All 14 privacy cases / 118 assertions pass in isolated Linux. Chrome: 32 cases / 1,446 assertions, no skips. RuboCop and Brakeman pass. |
| Authenticated accessibility | Settings/import and notification history checked in NL/FR/DE/EN at 320/1440px: keyboard, labels, targets, overflow and 18 local axe scans pass. The known logotype exemption is excluded. Read-button height increased to 32px. Physical devices and screen readers remain untested. |
| Fresh recovery | Snapshot `1020783f`, taken at 13:47 Europe/Brussels, restored and booted in 53 seconds. Candidate 0.8.0 and preceding 0.7.0 passed readiness, locale and authorization checks. Production identity/start time stayed unchanged; temporary data was removed. Older-image compatibility does not authorize a public rollback that loses security fixes. |
| Queued mail/privacy rehearsal | Only newly created synthetic notification jobs were executed, including selection/non-selection, through the test mail adapter. Scoped export/private-file and non-mutating erasure-inventory checks passed. No restored real-recipient job was executed, no external mail sent, no real deletion performed. |
| Mail/monitoring | Public SPF/DMARC and DKIM delegation are present. The internal mailbox loop is received but does not prove external authentication alignment. Hosted monitor recovery [40875197943](https://github.com/bg-ghub/lawrelay/actions/runs/40875197943) passed and closed incident 29. Backup/health timers are active. |

This records technical engineering evidence. The [master checklist](../release-master-todo.md) records current remaining steps and optional future checks.

## 29 October 2026 — 0.4.4

Non-disruptive checks against release 0.4.4:

| Check | Result |
| --- | --- |
| Application and public endpoints | Healthy image; homepage, login, readiness, operations and TLS probes passed. No failed queue jobs. |
| Host timers | Nightly backup and five-minute health timers active. Latest backup completed at 07:51 Europe/Brussels; host health passed at 08:04. |
| Storage and logs | Storage filesystem 10% used. Journals used 16 MiB; config files contained no explicit retention-age or size overrides. A reviewed retention policy is still needed. |
| External monitor | Latest five scheduled runs passed, including [run 40829650435](https://github.com/bg-ghub/lawrelay/actions/runs/40829650435). No incident was open. |
| Alert logic | Nine no-network monitor tests passed. The no-send Linux alert test preserved full events, suppressed duplicates and separated failures for different units. No alert was sent. |
| Fresh recovery and rollback | At 08:13 Europe/Brussels, the latest encrypted backup was restored into a disposable copy. Release 0.4.4 and compatible 0.4.3 both passed readiness, four-locale, authentication and authorization checks in 46 seconds. Containers had no network, queue workers or mail configuration; production identity/start time stayed unchanged and the disposable data was removed. |

Automated runbook review: for an outage, use external probes and the latest successful backup; for delayed email, inspect the queue and SMTP failure before retrying; for suspected disclosure, preserve private evidence and contain affected access; for a bad release, validate a compatible image on a restored copy before switching traffic. No outage, real access restriction or traffic switch was performed. Human response time, provider escalation and legal/customer communications remain untested.

## 28 October 2026

## Exercised

| Check | Evidence |
| --- | --- |
| Public external probe | Homepage, sign-in, readiness and certificate checks passed from the operator workstation outside Hetzner. |
| Alert helper behavior | Nine no-network Python checks pass, including generic operational-health JSON, duplicate suppression, destination restrictions and separation of synthetic recovery from a real incident. |
| Host alert payload | A no-send Linux test captures the complete failed-unit event, suppresses its duplicate and preserves a separate backup event. The corrected notifier and quoted systemd unit were installed; daemon-reload passed without an application restart. |
| Encrypted backup restore | A fresh backup completed at 21:02 Europe/Brussels: snapshot `b604b2e5`. The boot drill restored it successfully; all three database integrity checks passed and storage was safely extracted into a disposable copy. The separate integrity/archive restore service also passed afterward. |
| Current image boot | `lawrelay:0.2.1-9ff3ae9a0971` booted the restored copy; schema, databases, storage, four locales, CSRF-bearing login, dashboard, verified marketplace access, own private assignment and denied unrelated assignment/admin access passed. |
| Operational-health degradation and recovery | Only on the disposable 0.2.1 queue, a synthetic failed execution changed `/health/operations` from 200 to 503 with a generic status-only body. Removing that synthetic job restored 200. No production queue record was created, retried or deleted. |
| Compatible-image rollback | The preceding local image `lawrelay:0.2.0-dc4f2f19500c` booted the same migrated copy and passed the authentication, locale and authorization checks again. Its absent operations route was correctly skipped. No schema downgrade or production traffic switch was attempted. |
| Drill isolation | Both server processes explicitly unset the legacy queue environment flag. Process inspection confirmed no Solid Queue workers. Containers had no network, published ports or production credentials; no mail was delivered. |
| Production preservation | Container ID, image, running state and start time were identical before and after. Disposable containers and restored data were removed; production remained healthy and existing timers remained active. |
| Final host/public health | At 21:03 Europe/Brussels, the host health script passed via a transient unit without alert configuration or failure hooks. `/ready` and `/health/operations` both returned 200 with `{"status":"ok"}`. Backup and restore services reported success; nightly backup and five-minute health timers remained active. No SMTP send was invoked by this acceptance run. |
| GitHub-hosted real monitor | [Initial run 40759509569](https://github.com/bg-ghub/lawrelay/actions/runs/40759509569) and [final run 40760034630](https://github.com/bg-ghub/lawrelay/actions/runs/40760034630) passed homepage, sign-in, readiness, operations and certificate checks on deployed `0.2.1`. The hourly workflow is enabled on `main`. |
| Synthetic owner incident | [Failure run 40759779831](https://github.com/bg-ghub/lawrelay/actions/runs/40759779831) intentionally failed its probes and created [incident 11](https://github.com/bg-ghub/lawrelay/issues/11), assigned to the operator. The incident notification step succeeded. This sanitized issue is public following repository publication. |
| Duplicate suppression and recovery | [Repeated failure 40759896235](https://github.com/bg-ghub/lawrelay/actions/runs/40759896235) intentionally remained red, reused incident 11 and added no comments. [Recovery 40759957722](https://github.com/bg-ghub/lawrelay/actions/runs/40759957722) passed, added exactly one recovery comment and closed the synthetic incident. Real incidents use a separate marker. |
| Owner inbox delivery | The repository-notification API, filtered only to synthetic incident 11, returned `reason: assign` and `unread: true`. The notification was not marked read. This proves GitHub web-inbox delivery, not GitHub email delivery. The operator separately confirmed receipt of an earlier SMTP operational alert in Proton. |
| Application and browser regression | 172 Rails tests / 1005 assertions pass. Chrome, Firefox and Edge each pass 8 system tests / 175 assertions, covering four locales and 320/800/1280px. All six [merged-release CI jobs](https://github.com/bg-ghub/lawrelay/actions/runs/40759229378) pass. Public desktop pricing and French mobile signup were visually checked in a fresh guest session without submissions. |
| Fresh administrator mail | The post-deployment password-setup job completed through Migadu and the production queue had no failed or pending jobs. Recipient-side password-message arrival/header alignment and operator MFA setup remain unconfirmed. |

The final 0.2.1 boot/rollback drill ran at 21:02 Europe/Brussels and completed in 48 seconds. An earlier 0.2.0 drill at 20:44–20:45 completed in 47 seconds. Earlier checks found and corrected the legacy string-boolean queue flag and a process-inspection command before acceptance. These times describe technical exercises, not a production outage or traffic cutover.

## Still to verify separately

- GitHub schedules depend on the shared Actions budget and can be delayed. The account cap was restored to $15 with explicit operator approval, preserving the hard stop. Monitor recent successful scheduled runs; a later budget block prevents this external monitor too.
- GitHub web-inbox delivery is verified; GitHub email delivery/preferences are not. Password/verification email inbox placement and SPF/DKIM/DMARC still need recipient-side evidence.
- Confirm the corrected full event in the next coordinated real alert receipt; the regression test deliberately sends no email.
- Real-account MFA/key recovery, executing restored background jobs, nonempty attachment recovery, separate-host/provider recovery and an actual production traffic cutover were not exercised.
- The incident scenarios in the runbook are a technical tabletop. Human operator response time, counsel/regulator/customer communications and provider escalation still need the operator's rehearsal.

Paid checkout, invoicing and subscriptions remain outside this exercise and disabled for the beta.
