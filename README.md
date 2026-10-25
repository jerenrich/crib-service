<p align="center">
  <img src="ios/BabyCryMonitor/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="Crib Service app icon: a friendly bellhop beside a baby in a crib" width="240" height="240">
</p>

<h1 align="center">Crib Service</h1>

<p align="center"><strong>A tap on the wrist when your baby needs you.</strong></p>

Crib Service is designed to wake Mom or Dad with an **Apple Watch alert when the baby cries for longer than a chosen duration**. Leave one iPhone in the nursery, choose how long to wait, and receive alerts on your wrist.

### How it works

1. **Leave an iPhone in the nursery.** Set it to Listener mode, keep it plugged in, and start monitoring.
2. **Pair it with your iPhone.** Use Parent mode and connect your Apple Watch with the companion app.
3. **Choose your wait.** Pick 1, 2, 3, 5, or 10 minutes, or a shorter 5- or 30-second delay. The timer counts from the start of sustained loud sound, including the initial sound check. Brief noises are filtered out.
4. **Get a tap on your wrist.** Alerts repeat every 5 seconds by default, or every 2 seconds with Frequent alerts selected in Settings, until you snooze one on your Watch or iPhone, or the Listener confirms the configured quiet period. The Snooze button clears crying notifications on that device and pauses crying alerts for your chosen interval; a countdown and Resume alerts control let you end the snooze early.

### Made for the night shift

- **One compact Nightstand layout on both phones.** Listener and Parent share a sound state, live chart, fixed notice area and monitoring controls that fit without scrolling at standard text sizes. Alerts, snooze and connection changes keep the same positions; Details opens alert actions, recovery and device information. Larger accessibility text can scroll. Monitor, Activity and Devices tabs keep the sound view separate from history and setup.
- **Your timing, your settings.** Adjust the sound threshold, how long to wait, and how much quiet resets the timer.
- **A check before bed.** A four-step guide takes you through pairing, Watch notification setup, a confirmed wrist test, and starting monitoring. Returning users get a short nightly check.
- **Control from either iPhone.** Start once with the nursery app open. Pause Monitoring on either iPhone enters Standby: the microphone stays active while sound samples are discarded without detection, storage or sharing. Resume remotely, including while the Listener is locked. Parent Start is enabled only after a Standby heartbeat within the last 30 seconds confirms an active microphone; otherwise it directs you to start on the nursery iPhone. The separate Stop microphone action on the Listener asks for confirmation before fully releasing the microphone. Standby continues microphone power use and its privacy indicator; interruption or app termination may require reopening the nursery app. Live readings update the Parent controls and device status immediately; brief chart gaps retain the latest monitoring state until newer status arrives or that evidence expires. Parent confirms requested changes separately and warns if a request cannot be verified.
- **Nursery status at a glance.** Parent shows the same live sound-level chart as the nursery iPhone, with a short network delay. Check monitoring, battery, and connection status from the Parent phone or Watch.
- **Private audio.** Sound is processed on the nursery iPhone. Audio is never recorded or uploaded. Numeric levels are relayed for the live chart without being saved by the connection service. No accounts, ads, or analytics SDKs.

### What you need

Two iPhones running **iOS 17+**, an **Apple Watch running watchOS 10+** paired with the Parent iPhone, and internet access. Install Crib Service on both phones and its companion on the Watch, then enable notifications and direct Watch alerts. Use the bedtime setup guide to check Sleep Focus and haptics, and confirm you can feel a test alert.

To build and run it yourself, follow the [developer setup guide](docs/developer-guide.md#xcode-and-iphone-setup), including the [backend setup](docs/developer-guide.md#cloudflare-deployment).

### A few important limits

Crib Service currently detects sustained sound levels, so other loud noises can trigger it and quiet crying can be missed. Watch alerts depend on connectivity, notification permissions, and Focus settings; waking a sleeper is not guaranteed. It is not a medical monitor or a substitute for adult supervision.

---

[Developer guide](docs/developer-guide.md) · [Device testing checklist](docs/readiness-validation.md) · [Privacy and diagnostics](docs/diagnostics-review.md)

Watch alert testing mode is available in **Parent Settings → Watch alert testing mode**. Choose a frequency from 1–10 seconds and tap **Start Watch test**. Keep this iPhone app open and unlocked: the phone requests one real Watch push at a time. Stop takes effect locally, even offline. Locking/backgrounding the phone or closing Settings stops the test, and relaunch never resumes it. Internet is required to send; watchOS/Focus may delay or suppress wrist taps. An already sent push may still arrive. The updated Worker removes all old server test timers and relays only individual requests, without scheduling repeats or retries.

On **iOS 26+**, **Parent Settings → Silent alarm experiment → Test silent alarm in 5 seconds** requests alarm permission and schedules one AlarmKit alarm five seconds after permission is granted. It uses `AlarmTestSilence.caf`, a one-second mono 44.1 kHz 16-bit PCM silent asset bundled with both the iPhone and Watch apps. The app refuses to schedule if its silent asset is missing. Immediately lock the iPhone after starting the test, and wear the paired, unlocked Watch in Silent Mode with Prominent haptics. Check whether wrist taps repeat while both speakers remain silent. Apple controls Watch delivery and haptics; a silent asset does not guarantee either, and system fallback sounds remain possible. First test while your partner is awake. Closing Settings or locking the phone leaves the alarm scheduled. Stop it in the system alert or return to Settings and choose **Cancel / stop test alarm**, including after relaunch. This manual test is independent of crying alerts, server pairing and Watch push testing. Older iOS versions show that iOS 26 is required.

To test event-driven delivery, use **Parent Settings → Locked-phone delivery experiment → Arm Listener test for 10 minutes**, then lock the Parent phone. On the paired Listener, use **Settings → Diagnostics & simulation → Send silent alarm test to Parent**. The Listener sends one labelled, soundless notification to the Parent requesting background execution; while armed, the Parent attempts to schedule a silent alarm three seconds after receipt. Existing crying delivery is unaffected. Stop on the Watch, or use **Cancel remote test alarms** in Parent Settings. The experiment expires automatically after ten minutes. One supervised test on 25 October 2026 confirmed background receipt and scheduling while Parent J17 was locked, and the user confirmed repeating Watch taps with both devices silent. This remains an experiment: Apple may delay background execution, and overnight reliability and real crying integration are not yet established.

For real crying, enable **Parent Settings → Overnight wrist alarms → Silent Watch alarms** (iOS 26+). It is off by default and stays on until switched off. Grant alarm permission, keep the Parent iPhone locked and connected, and wear the unlocked Watch in Silent Mode with Prominent haptics. The Watch app can be closed. Existing notifications and reminders continue independently; the extra alarm is attempted only when the Parent can run app code and confirm that the episode is still relevant and not snoozed. Stopping the system alarm snoozes crying alerts for the configured duration. Acknowledging an existing crying notification also clears the silent alarm when the action reaches the Parent. Offline acknowledgements are retained for later sync. Settled alarms are cleared on the Parent's next successful status check; an alarm may continue until stopped if the Parent cannot check status. Test alerts do not activate the real-cry option. Test the complete setup before sleeping; background processing, Watch routing and a silent tone are not a guarantee of wrist delivery or silence on every OS version.
