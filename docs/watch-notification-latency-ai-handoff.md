# Apple Watch notification latency: independent analysis handoff

Snapshot: 26 October 2026, after the 13:40–13:41 UTC experiments. All times below are UTC (also London local time on this date). This is a standalone summary for another AI; no repository access is needed. Account details, device identifiers, tokens and credentials are omitted.

## Question to investigate

How can we make a paired Apple Watch alert promptly for this app, including while its iPhone is unlocked, without expensive infrastructure, continuous foreground execution, or unsupported APIs?

The user prioritizes the Watch. Duplicate Watch notifications/taps are acceptable. Muted audio is acceptable, but they want a felt Watch tap. We recognize APNs is best effort; “guaranteed” expresses the desired reliability, not an existing platform guarantee. Please distinguish documented mechanisms, plausible hypotheses and experiments that could falsify them.

## System and current state

- A nursery/Listener iPhone detects sustained crying and uploads an event to a Cloudflare Worker. A separate Parent iPhone is paired with the Watch. The Listener and Parent are different phones.
- Parent: iPhone 17 Pro. Watch: Apple Watch Series 12 (`Watch8,3`). Captured CoreDevice metadata reports iOS/watchOS **27.0.1**, with builds **24A446 / 24R365**, respectively. These are the values reported by the tools, rather than inferred OS versions. This is a signed development deployment using sandbox APNs.
- Backend: Cloudflare Workers + D1, with SQLite Durable Objects for reminder scheduling, durable acceptance receipts and APNs provider-token reuse.
- The Watch app is an iPhone companion: its signed `WKCompanionAppBundleIdentifier` matches the iPhone bundle, `WKRunsIndependentlyOfCompanionApp=false`, and installed bundle IDs/APNs topics match. This metadata was checked in source and signed builds.
- The Watch is worn/unlocked at its face during controlled trials. Time Sensitive permissions and interruption level 2 have been verified. Per-app Prioritize Notifications is disabled; summarization is disabled. This is not a controlled test with all Apple Intelligence globally disabled.
- Normal crying alerts currently send to phone and Watch in parallel, with no intentional delay, matching transport and collapse IDs, and matching default sound. Initial detection threshold is 5 seconds; real crying reminders are every 5 seconds. Measurements called “generation → …” start when the alert event is created, after the initial detection threshold.
- The latest separate-collapse-ID experiment is enabled **only for marked Test alerts on this pairing**. Normal crying alerts have not been switched to that strategy. Test alerts do not schedule crying reminders. The interactive custom Watch long-look view is restored.
- Apple's Bulletin Distributor/Alert Coordination logging profiles are installed on both devices at the user's request. Relevant phone and Watch sysdiagnoses have been collected and analyzed locally. Raw archives can contain unrelated notifications and are not included here. Developer-connection timeouts complicated installation/capture; they are not established as the cause of the measured notification wait.

Typical ordinary push, schematically:

```text
Phone topic: <iOS bundle ID>
Watch topic: <iOS bundle ID>.watchkitapp
apns-push-type: alert
apns-priority: 10
apns-id: <event UUID>                    # normally shared across destinations
apns-collapse-id: <event UUID>           # same on phone and Watch
                                        # repeats use episode UUID on both
```

```json
{
  "aps": {
    "alert": {"title": "Baby is crying", "body": "..."},
    "category": "BABY_CRY_ALERT",
    "thread-id": "<episode UUID>",
    "interruption-level": "time-sensitive",
    "sound": "default"
  },
  "eventId": "<event UUID>",
  "episodeId": "<episode UUID>",
  "createdAt": "<generation timestamp>",
  "cryStartedAt": "<cry-start timestamp>",
  "durationSeconds": 5,
  "diagnosticRef": "<pseudonymous backend event reference>",
  "deliveryAttempt": 1
}
```

Marked tests use `isTest:true` and labeled test text; presentation policy is otherwise comparable. The phone registers Snooze + Open nursery actions; the Watch registers Snooze. Category/thread match, but exact action-list parity has not been tested as a control.

## The problem and strongest evidence

Many direct Watch pushes reach notification processing quickly, yet the first tap/display comes roughly 14–16 seconds after generation. Long-look callback delay originally looked suspicious. System logs now explicitly show the Watch's **Bulletin Distributor waiting for companion information and timing out** before allowing the notification and requesting sound/vibration playback.

A particularly strong matched-identifier reproduction, **12:18:06.010**:

| Stage | Observation |
|---|---|
| Generation → both APNs request starts | 217 ms |
| Phone / Watch APNs request duration | 129 / 129 ms; accepted on attempt 1 |
| Watch notification date relative to generation | ~307 ms |
| Actual Parent UI state | SpringBoard `uiLocked=1` |
| Effective phone bulletin | Sound present, `includesSound=1`, `playLightsAndSirens:YES`; matching publisher ID |
| Watch starts direct-notification wait | 12:18:06.719617 |
| Matching affirmative companion decision arrives | 12:18:06.795195 — only 75.578 ms later |
| Watch times out anyway | 12:18:20.037019 — 13.317402 seconds waiting |
| Custom controller entry | 13.977 seconds after notification date |
| OS vibration playback request | 12:18:20.609672 — ~14.600 seconds after generation |

The custom view appeared only 41 ms after callback entry. Correct identifiers, sound parity, Time Sensitive, disabled prioritization and a verified locked phone did not eliminate this wait.

A private cache trace reports `universalSectionID (null)` / no reply information for the direct Watch section, whereas the companion reply is processed under the phone's universal section identifier. **This is a lead, not proof of broken app metadata or an OS mapping bug:** the lookup precedes the companion message, and the private field is undocumented. Installed companion metadata was verified correct.

## What we have tried

| Experiment | Result and qualification |
|---|---|
| Enable/fix Time Sensitive entitlement, signing and permissions | Verified interruption level 2 and device permission. Large Watch delay persisted; not a demonstrated latency fix. |
| Original custom long-look → native system notification view | Wearer: “about the same.” Native build had no custom long-look controller, yet late callbacks for the same event still occurred. Removing our SwiftUI interface did not demonstrate faster first taps. |
| Minimal custom view: two text labels, minimal parsing/journal, no model initialization/connectivity at entry | Wearer: “about the same.” Initial controller still entered 14.166 s after notification date; handling 6 ms, entry-to-view 24 ms. Original interactive view restored. |
| Reminder cadence increased from 2 s to 5 s | Reduces pressure/queued presentations. Did not establish resolution of the initial delay. Subsequent isolated Test alerts prove reminders are not necessary to reproduce it. |
| Give phone a 500 ms APNs request-start lead | Actual 500 ms lead verified; controller still 14.280 s after notification date; wearer “about the same.” Important confound: phone app was active and phone payload was quiet then. Not repeated under the later corrected sound/strict-lock conditions. 350 ms was discussed, not established as a successful measured trial. Request-start order does not prove device-arrival order. |
| Send only a direct Watch push, no phone push | Wearer “about the same.” One initial callback was 13.928 s after notification date. A different fast foreground callback occurred while earlier Watch notification views were active and is not a comparable first-tap result. Early trial phone lock state was not system-verified. |
| Parallel pushes with matching IDs | The original policy; matching publisher/collapse IDs verified in actual system logs, yet direct Watch waits persisted. |
| Disable per-app Prioritize Notifications | Wearer “about the same.” Later traces verify prioritization/summarization disabled and Intelligence processing ~140 ms versus an earlier ~2.8 s. Removing that extra delay did not remove the Watch timeout. |
| Match both payloads with no `aps.sound` | Wearer felt **no Watch vibration**. Controller delay still ~14.051 s. Sound omission is not equivalent to device Silent Mode. Default sound restored on both. |
| Fix phone foreground presentation options | Found incoming default sound being dropped by `willPresent` returning banner/list (24). Corrected it to include sound when present (26), retaining soundless behavior for intentionally quiet pushes. Tap returned, but subsequent strictly locked/sound-correct trial still timed out. |
| One-shot Test alerts with no crying/reminders | At 12:39:49, first tap quicker; next test at 12:40:05 delayed. First controller lag 1.529 s; second 15.528 s. No reminder scheduling in either. System trace shows fast first alert used the phone-forwarded path; its direct copy still timed out separately. |
| Phone-only APNs, let Apple forward to Watch | Three Watch-alerting tests at 12:50:11/22/26 requested vibration ~1.947/1.393/1.035 s after generation. Forwarded alert decisions took 36–38 ms, no 13-second wait observed. Wearer: “felt quicker.” A fourth earlier test reached the active phone and was explicitly not allowed to alert on Watch; exclude it from Watch successes. This route alone does not meet the user's unlocked-phone requirement. |
| Different `apns-id` UUID per phone/Watch request, still matching collapse IDs | Verified both requests actually had distinct transport IDs and started in the same logged millisecond. Locked/unlocked states system-verified. Both still delayed: waits 13.385 / 13.180 s; vibration requests ~15.508 / 14.752 s after generation. Override subsequently disabled. |
| Different collapse IDs for phone-forwarded and direct Watch copies | **Partial success**, detailed below. Fast forwarded tap + later direct tap with phone locked; delayed direct tap with phone unlocked. |
| iPhone AlarmKit silent-tone wrist alarm workaround | Separate 25 October supervised Listener → locked Parent trial scheduled a silent-tone alarm 3 s after receipt. User confirmed repeating wrist taps with both devices silent. Exact first-tap latency, unlocked-phone behavior and overnight reliability were not established. Optional real-cry integration exists but is disabled for this pairing; it was not active during the coordination experiments. Background scheduling/phone dependence remain limitations. |

## Latest separate-collapse-ID result

Only marked Test alerts use:

```text
Phone: apns-collapse-id = phone:<event UUID>
Watch: apns-collapse-id = watch:<event UUID>
```

Both retain one logical payload `eventId` and acknowledgement ID. `apns-id` returned to the ordinary shared event UUID so this control changes notification identity rather than transport identity. Sound, category, episode/thread and Time Sensitive are retained. There are still only two APNs requests per event, sent in parallel.

| Verified phone condition | Event generated | First OS vibration request | Second OS vibration request |
|---|---|---:|---:|
| Locked | 13:40:06.383 | **2.840 s**, phone-forwarded copy | **15.649 s**, direct Watch copy |
| Unlocked, Crib Service foreground | 13:41:17.356 | **15.562 s**, direct Watch copy | None |

Phone SpringBoard verifies `uiLocked=1` and `uiLocked=0`, respectively. The second test was requested at the Home Screen but app logs establish Crib Service foreground; keep that distinction.

For the locked case:

- Direct `watch:<UUID>` bulletin began waiting at 13:40:08.486390.
- Forwarded `phone:<UUID>` arrived at 13:40:08.661780 with `shouldPlayLightsAndSirens:YES`, and was allowed at 13:40:08.711689.
- OS playback request for its alert configuration: 13:40:09.223350.
- Direct copy timed out at 13:40:21.655285 after **13.168895 s**, then requested playback at 13:40:22.031538.
- The two playback requests are **12.808188 s apart** on one Watch clock. Wearer reported a fast first tap and later second tap.

For the unlocked case, the forwarded `phone:<UUID>` arrived with `shouldPlayLightsAndSirens:NO` and was denied. The distinct direct copy waited **14.496047 s** before timing out and alerting. Actual waits are not always exactly 13 seconds. Wearer reported a delayed tap.

All four destination requests were accepted on attempt 1; these duplicate taps are **not server retries**. Alert-configuration pointers in the same Watch trace distinguish forwarded versus direct playback, and each playback request included a non-nil vibration pattern. Later first-event controller reentries around acknowledgement are not new deliveries and have no extra matching notification playback in the captured window.

The first event also spent 974 ms acquiring a newly created shared APNs provider token, followed by ~440 ms per APNs request. The second reused that token and APNs took 133–134 ms. This contributes to generation-to-first-tap variation but does not explain the 13–14.5 s coordination waits.

## Earlier backend problems already addressed

These were real additional latency sources, not an explanation for the current Watch-side timeout:

- Initial-upload, status, heartbeat and reminder paths previously made too many sequential D1 calls. We batched reads/writes, reduced round trips, and added per-stage wall time versus provider-reported SQL time. Examples included a 2.521 s read with 0.431 ms SQL and a 6.6 s claim with 1.334 ms SQL. That establishes time outside SQL execution, not a proven Cloudflare internal root cause.
- Read-only fallbacks permit at most one extra read after 250 ms. Writes and APNs sends are not hedged. Slow write replies can be bypassed only when an exact ownership/heartbeat receipt proves the original transaction committed; there is no blind write replay.
- Durable per-target APNs acceptance receipts decouple accepted-result persistence from later reminders. Accepted targets are not resent; uncertain sends are not blindly retried. Clock, skip/claim, preparation, cleanup and storage-failure logging gaps were closed.
- Provider JWT churn caused genuine `TooManyProviderTokenUpdates` rejections earlier: one phone receipt lagged ~16.1 s while its Watch receipt arrived in ~156 ms. A credential-scoped Durable Object now persists/coalesces provider JWTs and rotates lazily at 50 minutes; warm sends use a memory cache. That transport problem is distinct from the later verified Watch coordination waits.
- Logging now includes 10,000-line app rings, bounded server diagnostics, request/event/attempt correlation, APNs response subtypes, clock estimates/uncertainty, lifecycle/process IDs and an independent bounded Watch callback-entry journal written before deferred main-actor work. No continuous polling or per-stage network telemetry is required.

Recent controlled pushes generally reach APNs/notification processing in hundreds of milliseconds to around a second; cold provider-token preparation can add latency. This does not prove all future backend stalls are eliminated.

## Measurement rules and limitations

1. APNs HTTP 200 means acceptance, not device receipt or vibration. Device delivery can occur before the APNs response returns to the Worker.
2. `UNNotification.date` is notification metadata. On a forwarded notification it is not an independently measured Watch radio-receipt timestamp.
3. Long-look callback, view appearance, app haptic request and **OS ToneLibrary vibration playback request** are different events. We now have the last of these for the key trials, but no instrumented physical motor timestamp. Human observations agree with the relevant fast/slow outcomes.
4. Cross-device generation totals are approximate; Watch clock estimates were sometimes unavailable or stale. Waits/tap-request intervals within a Watch system trace avoid that cross-device clock issue.
5. Opening an old notification can reenter a controller many seconds later. Do not count such callbacks as fresh delivery latency, a new APNs send, or a new tap without corresponding evidence.
6. Some early requested-locked tests were actually phone-foreground/unlocked. The strict-lock and latest ID experiments have explicit SpringBoard lock-state verification. Watch callback processes also changed between some experiments; sample sizes are small.
7. A single fast notification does not prove coordination is fixed: the earlier matching-ID trial was fast via forwarding while its direct copy still timed out.

## Interpretation and useful next questions

Strongly supported: a large part of the remaining delay is watchOS companion notification coordination before app presentation. Our custom rendering is not demonstrated to be the main cause. Distinct transport UUIDs did not help. Separate notification identities can preserve a fast forwarded path alongside a delayed direct path, but have not made the unlocked-phone Watch alert prompt.

Please assess:

- Is there a supported way to keep direct Watch presentation prompt while the phone is unlocked, or to disable this companion reconciliation for a notification/app? Avoid assuming transport IDs control reconciliation.
- Does the private section/universal-section cache evidence suggest a specific registration, category, or mapping issue? What observation would distinguish normal missing-yet cache state from a real mapping bug?
- Would matching category action sets, removing category/thread, or testing fresh unique threads isolate grouping versus reconciliation? These controls have not been done.
- Is a correctly configured phone-first arrival experiment still worthwhile? Our 500 ms request-lead test was confounded by foreground/quiet phone behavior and did not establish actual arrival order.
- Would a minimal fresh companion pair, controlled reboot, or clean registration/re-pair isolate stale OS state? No controlled destructive reset/re-pair has been performed; propose a minimally disruptive sequence.
- Would a **truly Watch-only app with no iOS companion relationship** avoid this particular wait? This is an architectural hypothesis, not a tested fix. Merely allowing independent installation retains a companion relationship.
- Are AlarmKit or WatchConnectivity useful supported alternatives under the actual execution/routing restrictions, without assuming background execution or delivery is guaranteed?
- What minimal reproduction and paired system-log excerpts should accompany an Apple Feedback report? Rank suggested experiments by diagnostic value, implementation effort, reliability and recurring cost.

## Primary references and local evidence

- [Apple DTS: 13-second coordination wait and matching request IDs](https://developer.apple.com/forums/thread/765669).
- [Later matching-ID reproducer and Apple engineer response](https://developer.apple.com/forums/thread/801596): timing/race issues; follow up through Feedback. Existing reporter's ID is **FB20339772**, not a report filed by us.
- [Remote notification request identifier derives from the collapse ID](https://developer.apple.com/documentation/usernotifications/unnotificationrequest/identifier).
- [APNs headers, unique transport IDs and best-effort delivery](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).
- [Phone/Watch forwarding and device-state routing](https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding).
- [Notification strategies for dependent, independent and Watch-only apps](https://developer.apple.com/documentation/watchos-apps/enabling-and-receiving-notifications).
- [Watch-only app metadata: no related iOS app](https://developer.apple.com/documentation/bundleresources/information-property-list/wkwatchonly).

For the maintainer: detailed chronology is in `docs/watch-notification-experiments.md`; backend/logging work is in `docs/diagnostics-review.md`; AlarmKit history is in `docs/readiness-validation.md`. Latest local trial evidence is in ignored `.local/separate-collapse-id-trial-2026-10-26/reproduction/` (`analysis.json`, app logs/journal and both system captures). Latest trial backend source passed **292 tests**, TypeScript checks and **80 live non-notifying smoke checks**. These verify implementation/regressions, not physical delivery guarantees. No raw diagnostics were uploaded to an external AI as part of preparing this handoff.
