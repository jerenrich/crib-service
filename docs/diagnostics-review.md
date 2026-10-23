# Logging and diagnostics review

Reviewed 23 October 2026. Scope: iPhone capture/detection, persistence, credentials, networking, pairing, heartbeats, outbox, phone notifications, WatchConnectivity, watchOS notifications, Worker API, APNs dispatch/retries, scheduled cleanup and privacy settings. This is a source review with local integration/simulator verification; it does not certify the live deployment or physical-device notification delivery.

Readiness rollout later on 23 October 2026: migration `0004_readiness.sql` applied and source `f489402` deployed as Worker version `a9d78941-56ce-414c-bb26-5acd5308dc9a`. Restricted request references and successful maintenance rows were verified live. Temporary-device readiness, pairing/replacement and deletion checks passed with no real push tokens or notifications; temporary metadata was deleted. Signed Debug apps were installed and launched in place on J14, J17 and the paired Watch. See [readiness validation](readiness-validation.md) for the rollout and remaining physical checks.

Rollout completed later on 23 October 2026: remote migration `0003_diagnostics.sql` applied; revision `be0b1dc` deployed as Worker version `5cb305ca-f99f-4a13-9c5c-ea2c92e862b7`; signed Debug apps installed and launched on J14, J17 and the paired Apple Watch. Live temporary-device API checks and diagnostic response headers passed. Temporary functional metadata was removed afterward. No test push was sent; physical notification delivery remains a separate check.

Post-deployment checks confirmed no pending migrations, 100% traffic on that Worker version, and a successful scheduled-maintenance diagnostic for the same version at `2026-10-23 06:27:27 UTC`. All three device processes were still running after launch. Automatic Worker observability remains disabled.

## Findings and changes

| Area | Finding | Result |
| --- | --- | --- |
| Server API | Unexpected errors became a generic 503 with no retained evidence. No app/server correlation. | Restricted D1 journal records operation, stage, outcome, HTTP status, elapsed time, server-generated request reference and deployed Worker version. Every API response includes `x-request-id`. |
| APNs and retry queue | Current event status/attempt count existed, but the history of attempts and cron recovery was missing. | Journal records accepted/rejected/blocked/ambiguous delivery, attempts, destination, preparation failures, safe APNs categories and interrupted claims. Keyed event references connect API and scheduled attempts. |
| Diagnostic failure | The app silently ignored file failures. | Visible persistence health, in-memory export fallback, atomic protected writes and exclusion from backups. Server journal failure never changes alert delivery; API responses report `x-diagnostics-status: unavailable`. |
| App networking | Most errors were visible only until another status replaced them. | Logs fixed operation/outcome categories, numeric HTTP/URL error codes, response request reference and elapsed time. Covers errors decoding successful responses too. |
| App lifecycle and audio | Recovery reasons, credential/storage failures and relaunch context were incomplete. | Build/OS export header, launch/foreground/background markers, permission and capture recovery categories, storage/credential failures and delivery states. No audio levels are added to the log. |
| Phone and Watch | Notification permission/registration and Watch sync failures were largely transient UI text. | Local permission, registration, receipt, sync and acknowledgement markers; numeric error codes where available. Watch has its own on-device diagnostic screen. |
| Privacy | Enabling normal server logging would introduce request metadata collection. | Automatic Worker observability stays disabled. Dedicated diagnostic columns prevent payload/exception serialization. No automatic app-log upload or third-party SDK. |

## Privacy and retention contract

Server diagnostic rows contain operational timestamps, a random request UUID, fixed operation/stage/outcome labels, numeric status/duration/attempts, phone/watch destination, a Worker release UUID and optional HMAC-SHA256 event reference. The HMAC is namespaced and keyed using the existing server pepper. It does not hash or retain device identity. References identify an event across retries; they are pseudonymous, not anonymous, and must be treated as sensitive operational data.

No diagnostic row contains request or response bodies, arbitrary URLs/paths/query strings, headers, IP addresses, device UUIDs, episode/event UUIDs, pairing codes, push tokens, credentials, configuration values, battery readings, crying timestamps/durations, audio/features or raw exception messages/stacks. Unknown routes and APNs reasons map to fixed fallback labels. Incoming correlation IDs are ignored. Diagnostics are accessible through operator D1 access only; there is no diagnostic API endpoint.

The minute cron attempts to delete journal rows older than seven days **before** delivery work. Cleanup failure records `diagnostic_cleanup_failed` when journal writes remain available, and allows alert delivery to continue. An insertion trigger caps the journal at the most recent 10,000 sequence entries, including during a cron outage. At high traffic, useful retention can be shorter than seven days; if cron is disabled or cleanup fails and no volume cap is reached, time-based deletion is delayed. D1 recovery/backups and provider infrastructure metadata have their own policies. Existing application tables still hold functional metadata under the README's separate retention rules; this change does not remove that metadata.

Local iPhone/Watch logs retain 500 lines. Routine successful status/heartbeat requests are sampled once per operation per 15 minutes. Equivalent network errors and frequently repeated failure markers are sampled once per minute; the first network recovery is retained. Alert network attempts are always logged so each retains its request reference. These are diagnostic samples, not complete request counts. File writes use Data Protection after first unlock and are excluded from backup. The user explicitly copies/exports the iPhone log. Watch logs are viewable under Wrist alerts → Diagnostics. Review exports before sharing: operational timestamps and request references can still reveal usage patterns.

Cloudflare documents that automatic invocation logs include request/response metadata and URL-derived messages: [Workers Logs](https://developers.cloudflare.com/workers/observability/logs/workers-logs/). Leave `[observability] enabled = false` in place. Avoid broad `wrangler tail`, request dumps, remote SQL dumps of functional tables, or enabling tracing as a default support procedure.

## Investigating an incident

1. Record approximate incident time/timezone and whether it involved detection, delivery, phone presentation or Watch presentation. Export iPhone diagnostics promptly from Settings → Diagnostics & simulation. For wrist-only symptoms inspect the Watch's Diagnostics screen too.
2. Find `network operation=... outcome=... request_id=...` around the failure. `transport_error` has a numeric URL error and often no response reference because no server response arrived. `decode_error` means an HTTP response arrived but did not match the app's expected data.
3. In Cloudflare's D1 console, query **only** diagnostic columns using the request UUID from the export:

   ```sql
   SELECT datetime(recorded_at/1000, 'unixepoch') AS utc,
          request_id, operation, stage, outcome, http_status,
          elapsed_ms, event_ref, attempt, target, release
   FROM diagnostics
   WHERE request_id = 'REPLACE-WITH-REQUEST-UUID'
   ORDER BY sequence;
   ```

4. For a dispatch row, query the same columns with `WHERE event_ref = 'REFERENCE-FROM-THAT-ROW' ORDER BY sequence` to follow cron retries. Do not query or share credentials/tokens/payloads. `release` identifies the Worker build to inspect; retain the matching source revision with deployment records.
5. Interpret the outcome:

   | Outcome | Meaning/action |
   | --- | --- |
   | `no_push_token`, `invalid_device_token` | Parent/Watch has no usable destination; check permission, signing/topic/environment and registration. |
   | `token_decryption` | Stored token cannot be decrypted with current configuration; inspect secret rotation/deployment, then re-register as appropriate. |
   | `provider_signing`, `provider_configuration`, `apns_environment` | Inspect APNs secret presence/format, key/team permissions, topic and development/production configuration without printing secrets. |
   | `apns_429`, `apns_500`, `apns_503` | Explicit retryable APNs response. Follow later attempts and cron health. |
   | `bad_topic`, `missing_topic`, `bad_priority`, `bad_expiration`, `bad_payload`, `payload_too_large`, `apns_rejected` | Explicit terminal rejection. Use the category, HTTP status and matching release to inspect payload construction. Unknown rejection text is deliberately discarded. |
   | `transport_unknown`, `dispatch_interrupted` | Acceptance is ambiguous. Check receiving devices; do not manually resend without evaluating duplicate risk. |
   | `sent` | APNs accepted the request. It does not prove phone/Watch display or haptic delivery. |
   | `internal_error` | Inspect operation/stage and matching release. Reproduce with synthetic data; raw production exceptions are deliberately not collected. |

6. Check cron liveness without reading functional metadata:

   ```sql
   SELECT datetime(MAX(recorded_at)/1000, 'unixepoch') AS last_success_utc
   FROM diagnostics WHERE operation = 'maintenance' AND outcome = 'ok';
   ```

   A missing or several-minutes-old result needs investigation. Check Cloudflare invocation/error metrics and configured cron trigger. Successful cron with no pending alerts still writes a completion row. `server_diagnostics=unavailable` in an app export signals missing journal evidence, not successful persistence.

## Remaining limits and operational work

- Deploy migration `0003_diagnostics.sql` before the updated Worker so diagnostic persistence is available. Rebuild/install both phone and Watch apps. These changes alone do not alter the live service.
- No automatic backend/cron outage notification or independent synthetic monitoring is configured. The optional Listener connection notices introduced in `0004_readiness.sql` require the backend and minute cron to remain healthy. Operators need a check for stale cron completion, elevated 503s, blocked/uncertain alerts and diagnostic storage failures. Do not point an unattended monitor at real child data; use a dedicated synthetic pair and define cleanup/notification ownership.
- The journal shares D1 with the application. A total D1 outage can prevent both application work and server diagnostic persistence. Client exports and Cloudflare aggregate metrics are the fallback. A killed Worker can leave no completion record; lease recovery records the affected dispatch on the next cron run.
- App logs cannot execute after a crash, force quit, watchdog kill or OS termination. Collect the matching iOS/watchOS crash, hang or jetsam report through Xcode/device diagnostics or Organizer, with user consent. Keep the exact release archive and dSYMs for symbolication. No crash/MetricKit upload SDK is installed by this change.
- Log sampling/caps intentionally trade exhaustive history for privacy, storage and performance. No source review can guarantee every future issue is diagnosable. Physical locked-screen, interruption, offline/reconnect, Focus/Silent Mode, wrist delivery and overnight checks still matter.

## Verification

Local tests exercise real D1 migrations and dispatch claims with mocked APNs, private-input exclusion, request/cron correlation, preparation failures, unknown APNs response sanitization, interrupted dispatch, retention, volume cap and diagnostic-write failure isolation. iOS tests exercise network success/HTTP/transport/decode diagnostics, invalid response reference exclusion, credential/URL/body exclusion, bounded persistence, backup exclusion and write-failure export. The complete iOS unit suite also covers the existing monitoring/outbox/heartbeat/Watch logic. Watch code is compiled with the shared logger; simulator results do not establish physical wrist behavior.
