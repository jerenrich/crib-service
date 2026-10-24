# Readiness release checks

The readiness release is deployed to the configured backend and installed on both iPhones and the paired Watch; see the rollout record below. For another environment, apply `0004_readiness.sql` before releasing the Worker and updated iPhone build. The physical checks require two iPhones and, for wrist delivery, a paired worn/unlocked Apple Watch. Do not mark a physical check passed from simulator results or an APNs acceptance receipt.

Record device/OS versions, build and Worker revision, timestamps, Focus settings and observed outcomes. Use a dedicated test pair for destructive checks. Never erase the family's active pairing as a test without the user's explicit intent.

## Live sound integration — 24 October 2026

The shared live sound chart is integrated on top of `c0d652b`, retaining the separate server/local warning preferences, Keep screen awake, battery readiness, monitoring controls, audio-route recovery confirmation, transient-error retries, and late warning recovery. Existing unit and UI tests are retained. Live readings are display data: they cannot confirm a monitoring command or arm/renew connection-warning deadlines. Unpairing and device deletion still succeed if the live relay is unavailable; D1 revocation remains authoritative and active sockets recheck their pairing.

Validation passed 96 Foundation core tests, 100 Worker/D1 integration tests, TypeScript source/test checks, 182 iOS unit tests, and all six simulator UI tests (shared chart, onboarding/settings persistence, monitoring failure, readiness/deletion confirmation, warning/screen preferences, and timeline). The combined unsigned iPhone/Watch device build and Worker deployment dry run passed. Simulator UI execution requires ad hoc signing (`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`); an unsigned app cannot access Keychain and produces an unrelated onboarding alert. This integration performs no backend deployment, physical-device installation, or real notification test. Physical live-chart, locked-nursery and mixed-network checks remain as described in the developer guide.

## Separate warning settings — 24 October 2026

The current source separates server connection alerts (on by default for new registrations, preserving existing preferences) from the optional local overdue-check warning (off by default, including upgrades). The local preference controls both Parent and Watch and clears legacy deadlines unless explicitly enabled. Keep screen awake is a separate, persisted Parent-only option, off by default. Manual locking can still pause checks. These app changes have not been installed on physical devices and require no backend deployment or migration.

After integration with main's nursery monitoring controls and battery checks, all 92 Foundation core tests and 171 iOS unit tests passed. Coverage includes independent preferences, upgrade cancellation, explicit opt-in, offline opt-out, pending-request/scheduling races, Watch snapshot compatibility, and saved screen-awake preferences. The Settings UI test passed, verifying both optional preferences default off, can be enabled, and survive app relaunch. The combined unsigned iPhone/Watch device build passed. Notification-service scheduling/cancellation runs outside the UI actor after simulator traces exposed a synchronous cancellation call blocking startup. Main's removal of the home-screen warning panel is preserved; the local warning's scheduling status appears in Settings. Physical Auto-Lock, Watch cancellation after sync and locked-screen delivery still require the checks below.

## Monitoring control checks

Apply `0009_monitoring_commands.sql` and deploy the updated Worker before installing the updated apps. Validation on 24 October 2026: 77 Foundation core tests, 90 Worker/D1 tests and TypeScript checks passed. The iOS suite passed all monitoring-control scenarios; its warning-cancellation expectation was updated for the first-launch notification fix and passed on rerun. The Parent UI test verified the error dialog and persistent warning. Foreground remote controls were subsequently tested on the physical phones as recorded below; the remaining scenarios still require physical checks.

Physical regression validation on 24 October 2026, 06:59:29–06:59:52 UTC: a temporary signed UI test runner tapped Start → Stop → Start → Stop in the installed J17 Parent app at source `c0d652b`, with J14's nursery app open. All four actions showed the expected confirmation and neither a “Monitoring not confirmed” dialog nor persistent warning appeared. The first Start was issued while J14 was already monitoring. The second Start restarted its microphone from stopped at 06:59:42 UTC through the original audio-route recovery condition (`monitoring_start_failed error=cancelled` followed by `audio_active`), verifying the false-warning fix on hardware. J14's diagnostics recorded both Stop actions, with the final Stop at 06:59:48 UTC. Screenshots verified J14 actively listening during the test and both phones stopped afterward; J17 still showed the stopped confirmation without a warning over 30 seconds later. The test passed with zero failures, monitoring was left stopped, and the temporary runner was removed. Existing pairing and settings were retained. This test does not cover a locked/suspended nursery app, network loss, or Watch alert presentation.

| Check | Expected observation |
| --- | --- |
| Pause from Parent with nursery screen locked | Detection stops, existing crying reminders end, microphone stays active, and Parent confirms Standby |
| Loud sound during Standby | Samples are discarded; no episodes, new crying alerts or live chart updates |
| Resume from Parent while Listener is locked in Standby | Existing capture is reused; Parent confirms monitoring and detection starts a fresh confirmation window |
| Stop microphone on Listener while in Standby | Microphone is released; Parent confirms Stopped after a fresh heartbeat |
| Audio interruption during Standby | Recovery preserves paused detection; failed recovery requires attention without claiming Standby remains available |
| Start from Parent with nursery app open | Nursery microphone becomes active; Parent confirms after a fresh post-request heartbeat proves it is active, including when audio recovery outlives the command callback |
| Start with nursery app suspended or force-quit | Parent shows a prominent failure/unverified alert and persistent red warning within 30 seconds; reopening the nursery app after expiry does not replay Start |
| Denied permission or unavailable microphone | Listener reports failure; Parent shows a prominent warning and never claims monitoring was confirmed |
| Network loss while changing monitoring | Parent shows that the action could not be verified; local nursery controls still work |
| Local Stop while a remote Start is pending | Local Stop wins over an older status response; no delayed restart |
| Parent Pause or Listener Stop during repeating Watch alerts | Outstanding crying alerts are retired; already submitted APNs notifications may still arrive |
| Nursery microphone stalls, or the nursery app is terminated and reopened, during repeating alerts | Reminders continue until acknowledged; only an explicit Pause/Stop or acknowledgement retires crying alerts |

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
| Warning settings and upgrade | Update Parent and Watch; inspect Settings before opting in; leave server alerts enabled and lock Parent for four minutes | Local overdue-check warning is off and legacy local deadlines are cleared; server alerts retain their preference; no local overdue notification from normal locking | Not run |
| Local offline warning | Enable Local overdue-check warning in Parent Settings; confirm it is armed on Parent and Watch, then remove their internet/phone connectivity on test devices | Each device's OS presents its already scheduled warning three minutes after the last verified Parent check; Watch notification haptic is felt under intended Focus/wrist settings | Native scheduling accepted on J17 and Watch before settings separation, 24 October 2026; disconnected delivery/wrist tap not yet observed |
| Parent checks suspended | Arm local warnings, then lock/background Parent without interrupting the network | An overdue-check warning can still fire after three minutes because iOS paused verification; it must not claim a proven router outage | Not run |
| Independent warnings | Disable server alerts while local warning is enabled; separately disable local warning while server alerts are enabled | Each setting controls only its own warnings; local opt-out cancels phone and Watch deadlines after sync | Not run |
| Keep screen awake | Enable in Parent Settings and wait past the normal Auto-Lock interval; then disable, background the app, change role and manually lock in separate checks | Parent remains awake while active and enabled; normal Auto-Lock resumes after disabling/backgrounding/changing role; manual locking still works | Not run |
| Recovery | Restore Listener internet after outage | Fresh active monitoring status and timeline recovery entry, with no recovery notification, sound or haptic | Not run |
| Stop/interruption | Stop Listener; separately exercise call, audio-route change and capture recovery | Stopped status/notice, or truthful recovery status; missing audio never counts toward cry duration | Not run |
| Opt out | Disable connection alerts, then repeat a fresh outage/recovery | No new connection notices | Not run |
| Power | Unplug Listener and exercise a test device under 20% battery | Parent shows battery/power, low-battery warning while fresh, stale qualifier when disconnected | Not run |
| Room calibration | Stop monitoring; run normal quiet room, fan/white noise, quiet sample and sustained representative sample | Fixed-threshold guidance matches measured noise/sample separation; quiet samples can use levels below −35 dBFS; insufficient separation gives no recommendation; no episodes or alerts created | Not run |
| Unpair/replacement | With test pair only, unpair; create code; pair replacement phone | Old relationship revoked; pending history cleared; counterpart notices change when online; no earlier episodes reappear | Not run |
| Delete | Delete a test device and shared history, then choose a role again | Shared server history and caller registration removed; local history cleared; new registration/pairing possible | Not run |
| Overnight | Run on intended charging/network setup with receiver locked and normal Focus | Record uptime, missed/false alerts, battery, interruptions, and actual notice latency; avoid assuming a notice wakes a sleeper | Not run |

Connection notices use the existing Watch-first destination selection. A registered but unreachable Watch does not prove delivery to the phone. Server outage, a disabled cron, or receiver disconnection can prevent notices. Validate actual presentation and preserve that limitation in user-facing claims.
