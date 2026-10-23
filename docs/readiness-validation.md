# Readiness release checks

The new features are implemented locally. Apply `0004_readiness.sql` before releasing the Worker and updated iPhone build. These checks require two physical iPhones and, for wrist delivery, a paired worn/unlocked Apple Watch. Do not mark a check passed from simulator results or an APNs acceptance receipt.

Record device/OS versions, build and Worker revision, timestamps, Focus settings and observed outcomes. Use a dedicated test pair for destructive checks. Never erase the family's active pairing as a test without the user's explicit intent.

## Automated validation — 23 October 2026

The shared workspace passed 52 Foundation core tests, TypeScript source/test type checks, 48 Worker/D1 integration tests, 95 iOS unit tests and both signed iPhone simulator UI scenarios. The iPhone target with its embedded Watch companion passed an unsigned device build, and Wrangler's deployment dry run produced a local Worker bundle. No live migration or deployment was performed for these changes.

Coverage added here includes outage opt-in/deduplication/recovery, stopped monitoring, explicit APNs rejection and Watch-token fallback, transport uncertainty, obsolete notice cancellation, settings acknowledgement, real test authorization, unpair/replacement/deletion isolation, non-blocking pairing refresh, calibration isolation and loud-room rejection. UI checks cover settings persistence, calibration navigation, the unpaired readiness flow and cancelling device deletion. UI launches use a Debug-only offline flag to prevent external API calls or notification registration.

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
| Room calibration | Stop monitoring; run normal quiet room, fan/white noise, quiet sample and sustained representative sample | Plausible levels and sensitivity guidance; quiet sample below floor does not qualify; no episodes or alerts created | Not run |
| Unpair/replacement | With test pair only, unpair; create code; pair replacement phone | Old relationship revoked; pending history cleared; counterpart notices change when online; no earlier episodes reappear | Not run |
| Delete | Delete a test device and shared history, then choose a role again | Shared server history and caller registration removed; local history cleared; new registration/pairing possible | Not run |
| Overnight | Run on intended charging/network setup with receiver locked and normal Focus | Record uptime, missed/false alerts, battery, interruptions, and actual notice latency; avoid assuming a notice wakes a sleeper | Not run |

Connection notices use the existing Watch-first destination selection. A registered but unreachable Watch does not prove delivery to the phone. Server outage, a disabled cron, or receiver disconnection can prevent notices. Validate actual presentation and preserve that limitation in user-facing claims.
