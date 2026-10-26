# Watch notification presentation experiments

The wearer reports that the **first notification tap**, rather than a later app-generated haptic, can coincide with a delayed long-look callback. An OS notification date is therefore insufficient evidence of perceived first-tap timing. Keep OS receipt, callback entry, UI appearance, app haptic requests and human observations separate.

Apple describes an automatic short look followed by a default or custom long look ([presentation](https://developer.apple.com/documentation/watchos-apps/presenting-notifications-on-apple-watch), [customization](https://developer.apple.com/documentation/watchos-apps/customizing-your-long-look-interface)). These experiments test whether the app's custom path contributes to the observed delay; they do not assume that removing a callback improves haptic latency.

## Build profiles

| Profile | Notification scene | Work at custom callback entry |
|---|---|---|
| `custom` | Existing interactive SwiftUI interface | Existing parsing, independent entry journal, deferred model update |
| `system` | No custom scene for `BABY_CRY_ALERT`; watchOS supplies its interface | No custom long-look entry callback exists |
| `minimal` | Two text labels, noninteractive | Payload parsing and bounded independent journal only; no model initialization, connectivity or model log from the controller/view |

All profiles retain the notification category and its registered foreground Snooze action. The normal build defaults to `custom`. `WATCH_SYSTEM_NOTIFICATIONS` and `WATCH_MINIMAL_NOTIFICATIONS` are mutually exclusive compilation conditions. The experimental minimal build defers eager WatchModel creation until an app window or an actual model-dependent operation needs it. Neither experiment changes backend code, APNs payload, priority, sound, Time Sensitive level, reminder cadence, or foreground haptic policy.

Build using an existing local signing configuration:

```sh
python3 scripts/build-watch-notification-experiment.py system \
  --signing-config /absolute/path/to/Local.xcconfig \
  --derived-data /private/tmp/CribLongLookSystem
```

Install only the reported `BabyCryWatch.app`. Use `minimal` for the second comparison and `custom` to restore the interactive presentation. The script passes arguments directly to Xcode without shell expansion and does not edit the project defaults or install anything itself.

## Evidence and protocol

The independent callback journal writes `watch_notification_presentation profile=system|minimal|custom` at process launch, before model initialization. Callback traces carry `presentation_profile`; retained history and asynchronous phone snapshots are deliberately not labeled using the collecting build because they may predate installation. Match callback IDs and process IDs as usual.

1. Preserve the earlier custom-view episode as baseline. Record the new build's installed profile and launch time.
2. Return the Watch to its watch face without force-quitting the app. Match the phone lock, wrist position, Focus and connectivity conditions across trials. Let the previous crying episode settle before generating a fresh one.
3. Observe the first tap and full notification appearance. Avoid browsing old notifications during the trial. Keep the existing five-second threshold and five-second reminder interval.
4. After the observation, collect server and device diagnostics. If the native interface did not wake the app, opening the Watch app afterward can recover OS notification history; that collection-time launch is not initial presentation. Record its time. Collapsed notifications can leave gaps in individual receipts.
5. Compare the human observation and OS receipt distributions. A native view having no custom callbacks is expected, and must never be reported as zero callback latency. Only test the minimal profile after the system-profile episode and observation have been captured.

On 26 October 2026, all 156 shared Swift tests and all 302 iOS unit/integration tests passed. All three Watch profiles built and signed successfully. The system build installed and independently confirmed `profile=system` at 09:59:22 GMT. The native and minimal profiles were subsequently tested on wrist, and the original interactive profile was restored. Both trials were reported as about the same for first-tap delay; neither demonstrated a perceived latency improvement. Local build logs and trial evidence are under `.local/long-look-experiments-2026-10-26/`.


## Native-view result

At 10:01:11.529 GMT, a fresh real episode generated one initial alert and four reminders. Apple accepted both destinations for all five events on attempt 1. Watch OS receipt differences were 607, 842, 535, 547 and 386 ms; these are raw cross-device wall-clock differences, not a physical haptic measurement. The wearer reported the first tap felt **about the same** as with the original custom view.

The independent journal confirms there was no custom long-look controller in that build. It records a foreground-delegate entry for the initial alert 405 ms after its OS receipt, then two more foreground-delegate entries for the **same event and attempt** 14.286 and 14.776 seconds after the same receipt. The backend sent each destination once, so these later callbacks are not evidence of an APNs retry. Native presentation still having these late entries, with no perceived improvement, points investigation toward system presentation/routing rather than custom SwiftUI rendering alone. It does not identify which internal watchOS behavior caused the repeated entries or establish the exact tap time.

The minimal profile was subsequently installed and verified at 10:06:03 GMT for the second comparison.


## Minimal-view result and restoration

At 10:07:11.563 GMT, one initial alert and three reminders were generated. All eight phone/Watch sends were accepted on attempt 1. Recorded Watch receipt differences were 825, 453, 404 and 119 ms. The initial custom-controller entry was **14.166 seconds after the OS receipt**, despite only **6 ms** of callback handling and **24 ms** between entry and view appearance. The wearer again reported the first tap felt **about the same**. These tests provide no reason to remove the interactive Snooze view as a latency fix. The original `custom` presentation was reinstalled and launched after the trials. The backend and five-second reminder setting were not changed.

## Research: a matching system coordination timeout

An [Apple DTS engineer explains a 13-second coordination timeout](https://developer.apple.com/forums/thread/765669): the Watch may wait to reconcile a companion iPhone notification before alerting. The engineer recommends matching request identifiers and simultaneous delivery. A [later watch-first coordination report](https://developer.apple.com/forums/thread/801596) describes the wait persisting despite matching identifiers; Apple acknowledges timing/race problems and recommends following up through Feedback Assistant.

Our current dual path already sends in parallel and uses matching collapse identifiers. This is a strong fit for the observations, not proof that this particular system race caused every delayed tap. Notification dates are metadata and do not measure the physical haptic. A next controlled comparison should test phone-first ordering or iPhone-only forwarding. Watch-only delivery is useful as a diagnostic control but can itself encounter the documented timeout, so it should not be presented as an established latency fix. Such routing comparisons have not yet been applied to real alerts in this work.

## Pair-scoped iPhone head-start trial

The next backend experiment gives the iPhone an intended **500 ms** lead over the direct Watch request. This duration is an empirical trial value, not an Apple-recommended interval. The desired outcome remains an earlier first Watch tap and display without an earlier distracting phone alert.

`WATCH_PHONE_HEAD_START_PARENT_ID` must exactly match the Parent and `WATCH_PHONE_HEAD_START_MS` must be an integer string from 1 through 500. Both are deployment variables; ordinary configuration leaves the trial off. Only events with eligible tokens and unsent destinations on both devices participate. Connection notices, single-destination sends, unrelated Parents, and retries for a single remaining destination retain their existing delivery path.

Both targets prepare their tokens normally. The head-start clock begins immediately before the phone's APNs request, after its provider-token acquisition. The Watch waits only after it is ready to make its own APNs request, with an independent **500 ms maximum intended wait**. A slow phone response never gates that wait; phone preparation failure releases it immediately. A late phone request receives a shortened lead rather than extending the Watch-ready deadline. Event-loop scheduling can still add timer lag. An APNs acceptance response does not prove device receipt or guarantee which device alerts first.

Per-target diagnostics retain `coordination_mode=phone_head_start`, configured lead/cap, `coordination_wait_ms`, the actual request-start lead when known, and a fixed wait outcome (`head_start_elapsed`, `phone_unavailable`, `wait_cap`). These fields contain no Parent identity or payload. The existing event reference joins both request timestamps. The phone payload stays soundless, Watch sound and Time Sensitive remain enabled, and request/collapse identities stay matched. There are no extra APNs sends or D1 queries for coordination.

Validation: source/test TypeScript checks and all **260 backend tests** pass. Tests cover a full 500 ms request lead, a phone APNs response still pending when the Watch starts, preparation failure, late/absent preparation, timer cleanup, matching request identities, unchanged sound/interruption payloads, and accepted-target retry protection. The Worker bundle dry run passed. No app update is needed. To stop the trial, deploy `WATCH_PHONE_HEAD_START_MS:0` or remove the two variables; a normal deployment without `--keep-vars` restores the default parallel behavior.

Deployed source `259d532` to Worker version `68d37ce9-ef44-48ee-a0d4-041f51803173` at 10:29 UTC on 26 October 2026. Version metadata confirms the 500 ms setting and trial Parent scope. The live smoke check passed after updating its diagnostic-header expectation to accept the existing successful-status sampling result (`sampled`). Its temporary registrations were removed; no push tokens or notifications were created by the smoke check.

The first real trial episode was generated at **10:33:05.139 UTC**. Both APNs requests succeeded on attempt 1, with an actual **500 ms** request-start lead for the phone. The Watch recorded receipt 1,131 ms after generation, but its first custom long-look controller entry remained **14,280 ms after that receipt** (15,411 ms after generation). The user's first-tap comparison was **“About the same.”** The phone's recorded receipt was only 56 ms before the Watch's; cross-device clock uncertainty prevents treating that small difference as proven device-arrival ordering. The callback journal was copied successfully; the main Watch log was unavailable after two developer-connection failures. This first trial provides no evidence that the 500 ms head start improves the first tap, nor does it establish an optimum relative to 350 ms. Preserve that distinction before increasing the deliberate Watch delay.
