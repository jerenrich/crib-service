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

A later review found J17 logged a foreground transition at 10:32:56.756 and foreground notification callbacks throughout that episode. Its `app_active=true` readiness log is consistent with an active phone during the trial, but is not a hardware lock-state measurement. Apple's routing rules favor an unlocked active phone, so the next controlled trial explicitly asks the user to lock J17 while wearing the unlocked Watch. Do not generalize this episode's result to locked-phone conditions without a repeat.

## Pair-scoped Watch-only push trial

**Current production state:** At the user's request, simultaneous phone and Watch delivery was restored on 26 October 2026 at 10:50 UTC, Worker version `abadf47c-b018-4c19-94c6-a164ffd26675` (source `042d0a2`). Readback confirms `WATCH_ONLY_PARENT_ID` and both phone head-start variables are absent. New alerts with both tokens use parallel delivery with no intentional delay. The API health check passed and there were no outstanding pending, sending or blocked trial deliveries for this Parent. Historical trial results below are retained; no app installation was required.

The user requested a trial with no phone alert push. `WATCH_ONLY_PARENT_ID` opts in exactly one Parent. On the first eligible claim, an event with a registered Watch token persists `delivery_mode=watch_only`, sends only to the Watch, skips the head-start wait, and suppresses the optional auxiliary phone alarm push. The same rule applies to fresh initial alerts, test alerts and server reminders. Connection-loss notifications retain their existing routing. Phone status polling and alert history continue normally.

The route is stored in the existing claim transaction, adding no remote query. A nullable, additive `delivery_mode` column requires migration `0013_watch_only_trial.sql` before deploying the Worker. Persisting the route prevents configuration changes from turning a pending single-target retry into dual delivery. Existing dual-target events retain their per-target states and never replay an accepted sibling. Acceptance still uses the durable outbox; uncertain transport never triggers a replay or a phone fallback. If no Watch token exists, ordinary phone delivery remains available. A definitively invalid Watch token is cleared by the existing compare-and-swap path and permits phone fallback on the next attempt; this is visible in diagnostics.

Allowlisted diagnostics record `notification_route=watch_only`, `phone_suppressed` and `phone_fallback`. The route label is not an Apple delivery acknowledgement. App installs, notification identifiers, priority, Time Sensitive and Watch sound are unchanged. All **268 backend tests**, source/test TypeScript checks and the Worker bundle dry run pass, including suppression of the optional phone alarm, fallback, ambiguity, retry after rollback, durable reminder acceptance and existing dual-target receipt protection.

To stop enrolling new alerts, remove `WATCH_ONLY_PARENT_ID` on the next deployment. Already claimed trial events retain their route through completion. Deploying this trial without `--keep-vars` also removes the previous phone head-start variables, so the two trials do not overlap.

Deployed source `bba9ffa` to Worker version `63aff9c6-bbba-4835-bbda-fe9976289744` on 26 October 2026 at 10:41 UTC. The additive migration completed successfully. Version metadata verifies the intended Parent scope and absence of both head-start flags. All **80 live smoke checks** passed and temporary registrations were deleted; the smoke check registered no push tokens and sent no notification. A real trial with J17 locked and a first-tap observation is still required before judging latency improvement.

The subsequent capture through **10:45:08 UTC** contains **two initial alerts and eleven reminders**: all thirteen were persisted as Watch-only and accepted by APNs on attempt 1, with no phone dispatch, fallback or coordination wait. The user was asked to lock J17 and reported that the first tap felt **“About the same.”** Physical phone lock state throughout the episodes is not established by the app logs.

For the **10:43:57.836** initial alert, Listener upload started after 58 ms. Backend receipt to APNs request took 196 ms, including provider-token acquisition of 86 ms; the APNs response took 407 ms. Watch recorded receipt was approximately 752 ms after generation, but raw controller entry was **13,928 ms after that receipt** (approximately **14.68 seconds** after generation). Main-actor wait and app handling were only 35 ms and 9 ms; the view appeared 38 ms after raw entry. Watch-only delivery did not remove the large callback wait in this trial.

For the **10:44:29.631** initial alert, backend receipt to APNs request took 112 ms and its APNs response took 610 ms. Watch recorded receipt was approximately 734 ms after generation; the foreground delegate entered 365 ms after receipt (approximately 1.10 seconds after generation). Earlier long-look notification views were active around this episode, so that callback cannot establish improved first-tap latency at the watch face. Later callbacks for older reminders are presentation observations, not new network deliveries or measured haptics. Cross-device totals remain approximate: the last Watch clock estimate had 549 ms uncertainty and was about eleven minutes old. The receipt-to-entry gaps are measured on the Watch's own clock. Twelve captured events had Watch receipt evidence by the log-copy time; the final reminder's receipt was not yet captured. No physical haptic timestamp is available.

Apple's [DTS explanation](https://developer.apple.com/forums/thread/765669) predicts that an absent phone notification can itself cause a 13-second wait, so this is a controlled device experiment rather than an assumed fix. A supported next alternative is phone-only APNs with [system forwarding](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding): with the paired phone locked and the Watch worn and unlocked, the Watch is the selected destination. This removes the competing direct Watch push without requiring a visible phone alert first. A separate settings experiment can disable notification summaries/prioritization for Crib Service; [Apple's support instructions](https://support.apple.com/en-za/108781) describe those controls. That is a hypothesis about processing delay, not a demonstrated cause on these devices. Keep routing and settings experiments separate. Apple's [identifier documentation](https://developer.apple.com/documentation/usernotifications/unnotificationrequest/identifier) confirms the existing matching `apns-collapse-id` headers map to matching request identifiers. No supported coordination-disable API was found in the reviewed documentation. A separate standalone Watch app would be a larger architectural experiment; merely allowing independent installation does not remove the companion relationship.
