# Readiness release checks

The readiness release is deployed to the configured backend and installed on both iPhones and the paired Watch; see the rollout record below. For another environment, apply `0004_readiness.sql` before releasing the Worker and updated iPhone build. The physical checks require two iPhones and, for wrist delivery, a paired worn/unlocked Apple Watch. Do not mark a physical check passed from simulator results or an APNs acceptance receipt.

Record device/OS versions, build and Worker revision, timestamps, Focus settings and observed outcomes. Use a dedicated test pair for destructive checks. Never erase the family's active pairing as a test without the user's explicit intent.

## Fixed threshold integration

The fixed-threshold changes are integrated with readiness, connection alerts and device management. Calibration now recommends a selectable absolute level, and the server normalizes retired sensitivity fields in saved settings and applied-configuration heartbeats. This integration is not covered by the earlier rollout record below: deploy the updated Worker before updating both iPhones, then repeat the physical checks. No schema migration is needed.

Validation on 23 October 2026: 57 Foundation core tests, TypeScript source/test checks, 50 Worker/D1 integration tests, 100 iOS unit tests and both iPhone simulator UI scenarios passed. The UI flow verifies that selecting −45 dBFS persists across relaunch. Calibration tests exercise recommended thresholds against the actual detector, including samples below the previous −35 dBFS floor. The combined iPhone/Watch unsigned device build and Worker deployment dry run passed. No live deployment, physical installation or real push test was performed for this integration.

## Automated validation — 23 October 2026

The shared workspace passed 52 Foundation core tests, TypeScript source/test type checks, 48 Worker/D1 integration tests, 95 iOS unit tests and both signed iPhone simulator UI scenarios. The iPhone target with its embedded Watch companion passed an unsigned device build, and Wrangler's deployment dry run produced a local Worker bundle. After merging the 15-second heartbeat update, all 95 iOS unit tests passed again. Deployment followed as recorded below.

Coverage added here includes outage opt-in/deduplication/recovery, stopped monitoring, explicit APNs rejection and Watch-token fallback, transport uncertainty, obsolete notice cancellation, settings acknowledgement, real test authorization, unpair/replacement/deletion isolation, non-blocking pairing refresh, calibration isolation and loud-room rejection. UI checks cover settings persistence, calibration navigation, the unpaired readiness flow and cancelling device deletion. UI launches use a Debug-only offline flag to prevent external API calls or notification registration.

## Live rollout — 23 October 2026

- Source: `f489402`, merged and pushed to `main`.
- Applied only the pending additive migration `0004_readiness.sql` to the existing `baby-cry-monitor` D1 database.
- Published Worker version `a9d78941-56ce-414c-bb26-5acd5308dc9a` at the configured workers.dev origin. Existing database binding, secrets, development APNs environment, disabled automatic observability and minute cron were preserved. Previous Worker version: `0e2a1f08-666e-4dd7-98f1-3bd5626e0ef6`.
- Live smoke checks passed for authentication, temporary registration/pairing, five-second settings and bounds, applied-configuration acknowledgement, diagnostic request references, connection preference default/role/opt-in/out, marked tokenless test events, unpair/replacement, old-history removal and device deletion/revoked credentials. Temporary devices and metadata were deleted through the API. No real push token was submitted and no push was sent.
- Three consecutive successful maintenance records from the new Worker version confirmed that scheduled work runs after deployment.
- Signed Debug app and companion built for the configured Apple team with development APNs and the live backend URL. Installed in place and launched successfully on J14 (iPhone 14 Pro), J17 (iPhone 17 Pro) and Jordan’s Apple Watch. No app-data reset or unpairing was performed on these devices.
- Monitoring must be restarted on the Listener after installation. Parent → Ready for tonight? provides the live checklist and real test request. Connection alerts remain opt-in. Presentation, wrist haptics, room calibration and overnight behavior require the physical checks below.

## Physical validation

| Check | Procedure | Expected observation | Hardware result |
| --- | --- | --- | --- |
| Setup | Pair, start Listener, connect power and open Parent's Tonight's check | Pairing, active microphone report, power, registration and settings checks pass as fresh data arrives | Not run |
| Full push path | Send a test from Listener with Parent locked and Watch app closed; repeat with intended Sleep Focus | Marked real test is visible/felt on selected receiver; confirm receipt in Parent | Not run |
| Parent test | Send real test from Tonight's check and lock phone | Marked test arrives; receipt remains unconfirmed until acknowledged | Not run |
| Settings | Change alert duration on Parent while Listener is online | Saving → waiting → applied; actual Listener duration changes | Not run |
| Offline settings | Disconnect Listener, change duration, reconnect | Parent does not claim applied until Listener reports the new configuration | Not run |
| Connection loss | Opt in, start Listener, then disconnect only Listener internet for at least four minutes | One connection-loss notice; Parent shows lost connection when opened | Not run |
| Recovery | Restore Listener internet after outage | One recovery notice and fresh active monitoring status | Not run |
| Stop/interruption | Stop Listener; separately exercise call, audio-route change and capture recovery | Stopped status/notice, or truthful recovery status; missing audio never counts toward cry duration | Not run |
| Opt out | Disable connection alerts, then repeat a fresh outage/recovery | No new connection notices | Not run |
| Power | Unplug Listener and exercise a test device under 20% battery | Parent shows battery/power, low-battery warning while fresh, stale qualifier when disconnected | Not run |
| Room calibration | Stop monitoring; run normal quiet room, fan/white noise, quiet sample and sustained representative sample | Fixed-threshold guidance matches measured noise/sample separation; quiet samples can use levels below −35 dBFS; insufficient separation gives no recommendation; no episodes or alerts created | Not run |
| Unpair/replacement | With test pair only, unpair; create code; pair replacement phone | Old relationship revoked; pending history cleared; counterpart notices change when online; no earlier episodes reappear | Not run |
| Delete | Delete a test device and shared history, then choose a role again | Shared server history and caller registration removed; local history cleared; new registration/pairing possible | Not run |
| Overnight | Run on intended charging/network setup with receiver locked and normal Focus | Record uptime, missed/false alerts, battery, interruptions, and actual notice latency; avoid assuming a notice wakes a sleeper | Not run |

Connection notices use the existing Watch-first destination selection. A registered but unreachable Watch does not prove delivery to the phone. Server outage, a disabled cron, or receiver disconnection can prevent notices. Validate actual presentation and preserve that limitation in user-facing claims.
