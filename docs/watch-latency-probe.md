# Standalone Watch and corrected phone-first experiments

26 October 2026. Implements experiments 1 and 3 from the latency investigation.

## Standalone Wrist Probe

`WatchLatencyProbe` is a separate single-target watchOS app, bundle/topic
`com.jordanerenrich.cribservice.latencyprobe`. Its signed Info.plist uses
`WKWatchOnly=true`, with no `WKCompanionAppBundleIdentifier` and no
`WKRunsIndependentlyOfCompanionApp`. The installer rejects defining both
Watch-only and independent-companion keys. The iPhone target neither embeds nor
depends on the probe. It has no WatchConnectivity, custom notification scene,
polling, background session, backend credentials or app-generated haptics.

Enable alerts in the app, then use **Local test in 10s**, return to the Watch
face and lower the wrist. Native notifications request default sound and Time
Sensitive. Watch Silent Mode can mute sound without removing the payload sound
field. Each local test cancels any pending local probe request and uses a fresh
UUID. It does not cancel delivered notifications or affect Crib Service.

The app privately exports its current APNs token to
`Library/Application Support/WatchLatencyProbe/push-token.txt`. The bounded
`callbacks.jsonl` and optional `callbacks.previous.jsonl` in the same directory
contain authorization settings, local scheduling time/expected fire time and
foreground/response entry observations. No token or notification body is logged.
Background notification presentation need not invoke the delegate. A response
callback records a user interaction, not initial delivery or motor actuation.

### Build and signing

Run `python3 scripts/generate-project.py`, open
`ios/BabyCryMonitor.xcodeproj`, select **WatchLatencyProbe** and a Watch device
destination. Use the configured Apple Developer team and automatic signing.

On this Mac, Xcode 27.1's GUI showed the valid Apple account and Admin team while
its command-line account list was empty and automatic provisioning reported
`No Accounts`. Building through Xcode's GUI successfully created a dedicated
push/Time Sensitive development profile. This is a working provisioning path;
the underlying account-list mismatch has not been repaired or explained.

The final signed app must have development APNs and Time Sensitive entitlements,
an exact application identifier, Watch-only metadata and no companion key.
Install it alongside the existing companion app. No phone reinstall is needed.

### Remote test transport

The operator registers a separate, unpaired temporary Parent using
`scripts/watch-latency-probe.py`. The private credential file and exported token
must stay in ignored `.local/` storage. Registering this device does not pair it
with a Listener or modify the nursery pairing.

The endpoint `POST /v1/watch-latency-probe/push` requires that authenticated
Parent's UUID to equal the deployed `WATCH_LATENCY_PROBE_PARENT_ID`, rejects
paired registrations and limits attempts to six per ten minutes. It uses the
temporary registration's encrypted token with a fixed standalone topic, native
alert, default sound, Time Sensitive, a fresh shared request/collapse UUID and a
60-second expiration. It creates no nursery events, reminders or retry outbox.
Uncertain sends are reported without automatic replay. The existing persistent
provider-token authority is reused, avoiding a second local JWT issuer.

Example operator sequence (replace the paths with private local paths):

```sh
python3 scripts/watch-latency-probe.py --credentials .local/probe.json register \
  --backend https://baby-cry-monitor.jordan-erenrich.workers.dev
# Deploy WATCH_LATENCY_PROBE_PARENT_ID using the returned temporary UUID.
# Copy the token from the standalone app's container without printing it.
python3 scripts/watch-latency-probe.py --credentials .local/probe.json token \
  --file .local/probe-token.txt
python3 scripts/watch-latency-probe.py --credentials .local/probe.json push \
  --condition unlocked-home --output .local/probe-trial-1.json --delay 15
```

The operator's delay occurs on the Mac before the request; the Watch can stay
at its face. Condition labels are **requested**, not automatically verified.
Never interpret an APNs acceptance or HTTP response as a vibration timestamp.
After the experiment, delete the temporary registration using the script's
`delete` command and remove its deployed trial flag. Its credentials are retained
privately until then so cleanup and further supervised tests remain possible.

## Corrected phone-first control

`PHONE_HEAD_START_TEST_PARENT_ID` opts in one existing Parent. Only marked Test
alerts receive a 500 ms phone APNs request-start lead. Default sound, Time
Sensitive, payload IDs and request/collapse identities match on both destinations.
The Watch-ready wait remains capped at 500 ms; a phone preparation failure or
stalled HTTP response cannot indefinitely hold back the Watch. Recorded request
start offsets and wait outcomes reveal whether the intended lead was achieved.
The delay does not establish arrival order on the devices.

Real crying and reminders remain parallel. This trial refuses to add a lead if
another routing/identity trial is enabled for the same Parent. At deployment the
earlier separate-collapse flag was removed, along with other old routing flags.
Legacy head-start settings remain supported in source but are not enabled.

Trigger each one-shot **Send test push** from the Listener so J17 can stay in
the intended condition. Test locked, unlocked at Home, and unlocked with Crib
Service foreground separately. Keep Watch apps and notification long looks
closed between trials and allow at least 30 seconds between isolated sends.
Record actual device order and first OS playback request in paired system logs.
A fast phone-only result does not satisfy the Watch-first requirement.

## Validation and initial observation

- Standalone watchOS build and device installation passed; signed metadata and
  push/Time Sensitive entitlements were checked.
- All 299 Worker tests passed, including exact trial scoping, real-cry/reminder
  parallel behavior, matched phone-first metadata, standalone authorization,
  fixed topic, JWT reuse, rate limiting and absence of automatic uncertain retries.
- Source/test TypeScript checks, deterministic project generation, Python syntax
  checks and Worker deployment dry run passed.
- All 80 live regression smoke checks passed using temporary registrations with
  no push tokens; the smoke registrations and shared metadata were deleted.
- Worker `4c64ba7f-d638-45cf-a18f-08c00940718e` was deployed. Binding readback
  confirmed only the new phone-first test and standalone registration flags,
  with the existing APNs configuration and secrets retained.
- The wearer reported the first standalone local test alerted at **10 seconds**
  after pressing the button, without the extra ~13-second wait, under the
  requested unlocked/Home Screen phone condition. This is one human observation;
  it does not yet establish remote latency, repeated reliability or a motor timestamp.

### Standalone system-log result

The first local event was due at approximately **14:47:41.871 UTC**. The Watch
allowed it at 14:47:42.108811 after a **97.089 ms** coordination wait and requested
ToneLibrary playback with a non-nil vibration pattern at **14:47:42.935936**:
about **1.065 s after the requested fire time**, without the previous long timeout.

The direct remote event was created at **14:49:20.096 UTC**. Watch system logs
record remote receipt at **14:49:21.835831**, approval at 14:49:22.107341 after a
**157.510 ms** coordination wait, and OS playback with a non-nil vibration pattern
at **14:49:22.358008**. This is **522.177 ms from Watch receipt to playback**, all
on one Watch clock, and approximately **2.262 s from backend creation to playback**
across clocks. There was no 13-second timeout for either probe event.

The Watch-only app still performs a brief companion suppression check; the
observation supports prompt resolution here, rather than proving that all
companion communication has disappeared. The wearer confirmed J17 was unlocked
for the remote test but could not estimate the tap timing; Home Screen was the
requested condition and was not independently established by the phone capture.
OS playback requests are not instrumented motor timestamps. These first trials
are promising, not evidence of an overnight delivery guarantee.

### Corrected phone-first trial observations

Two marked tests were generated at **15:04:29.522** and **15:05:24.600 UTC**.
The wearer clarified that J17 was **unlocked with Crib Service foreground**.
The initial report of no Watch tap was subsequently clarified as a long wait
before tapping. Neither trial should be described as a verified Home Screen test.

Backend diagnostics confirm an actual **500 ms APNs request-start lead** for
the phone in both cases, with phone and Watch accepted on attempt 1. Old
identity/routing overrides were absent. Phone system logs record receipt at
15:04:30.254007 and 15:05:25.223767; Watch notification-processing receipt logs
occur at 15:04:47.424274 and 15:05:25.608660. The phone foreground delegate returned
presentation options **26** (banner/list/sound) for both, addressing the earlier
quiet-phone confound.

| Event generated (UTC) | Watch coordination wait | First matched OS playback request |
|---|---:|---|
| 15:04:29.522 | 15:04:47.606909–15:05:01.064434: **13.457525 s** | **15:05:01.635891**, non-nil vibration pattern; approximately **32.114 s after creation** |
| 15:05:24.600 | 15:05:25.888771–15:05:39.427641: **13.538870 s** | No matched playback request identified in the inspected 15:04–15:06:15 window; approval alone is not a measured tap |

The first test also has substantial time before the Watch notification-processing
receipt log. Do not attribute the entire 32 seconds to its 13.46-second wait.
Its earlier notification date is metadata, not a physical radio-receipt timestamp.
Generation totals and phone-versus-Watch ordering compare clocks without a new
offset estimate; coordination waits are measured entirely within one Watch trace.

For the second event, the phone-forwarded bulletin reached the Watch at
15:05:25.787539 with `shouldPlayLightsAndSirens:NO`, and the forwarded alert was
denied. It arrived **101.232 ms before the direct copy began its wait**, yet the
direct copy still timed out. It did not precede the Watch's direct remote-receipt
log, so this is not proof that every possible longer phone lead would fail.
Both actual controlled events used the foreground phone condition; locked and
Home Screen variants of this corrected trial have not been established.

Additional marked tests and later real crying events were present in backend
history; they are not folded into these isolated first-tap measurements.
The tested 500 ms strategy did not resolve the unlocked-phone requirement. Its
flag was removed after collection. Final Worker version
`c4731fb7-2bd3-4152-9fa3-95a4ce4bed9e` retains only the isolated standalone-probe
flag; readback verifies that phone-first and earlier identity/routing flags are
absent. Ordinary marked tests are parallel again. Real crying and reminders
were parallel throughout. Wrist Probe remains a pilot, not the real-cry destination.

Local build, installation, deployment, trial receipts and private exports are
under `.local/watch-latency-probe-2026-10-26/`. Paired system captures may contain
unrelated notifications and must remain local.

## Developer connection findings

Xcode and the command-line tools both use Xcode 27.1 on this Mac. Developer Mode
was confirmed enabled on the Watch. Installation and app-container copying worked,
but some later detail queries and diagnostic requests failed. Local CoreDevice
logs show successful tunnel establishment followed by remote-service startup
errors (`com.apple.mobile.lockdown.remote.trusted`, `kAMDNoResourcesError`), an
RSD heartbeat failure and tunnel cancellation. Bluetooth control-channel discovery
was present. These observations do not establish the underlying cause or imply
that APNs takes the same path.

The Mac's Wi-Fi was 5 GHz, channel 149, with strong signal (about -44 dBm and
-98 dBm noise); its configured VPN was disconnected and the application firewall
was disabled. The Watch's actual Wi-Fi association was not independently checked.
After the wearer woke the Watch and kept it near J17, a serialized retry began
producing the Watch sysdiagnose archive. One successful retry does not establish
a permanent connection fix.

For future collection, keep the Watch awake/unlocked and close to the Mac/phone
while connecting, serialize developer operations, and use a charger for long
diagnostic transfers when wrist alert measurement has finished. During alert
trials, restore the worn/unlocked, Watch-face condition and leave debugger/app
activity out of the measurement window. Apple's Xcode guide recommends a shared
2.4 GHz Wi-Fi network for iPhone/Watch debugging and a network that permits peer
connections; compare that setup after preserving the current captures. Avoid
attributing a `utun` interface to a VPN: CoreDevice itself creates virtual tunnels.

References: [Apple Watch debugging Wi-Fi guidance](https://help.apple.com/xcode/mac/current/en.lproj/devc48eab05e.html),
[Wireless-device setup](https://help.apple.com/xcode/mac/current/en.lproj/dev3e2f4ee6d.html).
