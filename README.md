<p align="center">
  <img src="ios/BabyCryMonitor/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="Crib Service app icon: a friendly bellhop beside a baby in a crib" width="240" height="240">
</p>

<h1 align="center">Crib Service</h1>

<p align="center"><strong>A tap on the wrist when your baby needs you.</strong></p>

Crib Service is designed to wake Mom or Dad with an **Apple Watch alert when the baby cries for longer than a chosen duration**. Leave one iPhone in the nursery, choose how long to wait, and receive alerts on your wrist.

### How it works

1. **Leave an iPhone in the nursery.** Set it to Listener mode, keep it plugged in, and start monitoring.
2. **Pair it with your iPhone.** Use Parent mode and connect your Apple Watch with the companion app.
3. **Choose your wait.** Pick 1, 2, 3, 5, or 10 minutes, or a shorter 5- or 30-second delay. The timer starts after a few seconds of confirmed crying-like sound.
4. **Get a tap on your wrist.** Alerts repeat every 5 seconds by default, or every 2 seconds with Frequent alerts selected in Settings, until you snooze one on your Watch or iPhone, or the Listener confirms the configured quiet period. The Snooze button clears crying notifications on that device and pauses crying alerts for your chosen interval; a countdown and Resume alerts control let you end the snooze early.

### Made for the night shift

- **One compact Nightstand layout on both phones.** Listener and Parent share a sound state, live chart, fixed notice area and monitoring controls that fit without scrolling at standard text sizes. Alerts, snooze and connection changes keep the same positions; Details opens alert actions, recovery and device information. Larger accessibility text can scroll. Monitor, Activity and Devices tabs keep the sound view separate from history and setup.
- **Your timing, your settings.** Adjust the sound threshold, how long to wait, and how much quiet resets the timer.
- **A check before bed.** A four-step guide takes you through pairing, Watch notification setup, a confirmed wrist test, and starting monitoring. Returning users get a short nightly check.
- **Control from either iPhone.** Start once with the nursery app open. Pause Monitoring on either iPhone enters Standby: the microphone stays active while sound samples are discarded without detection, storage or sharing. Resume remotely, including while the Listener is locked. Parent Start is enabled only after a Standby heartbeat within the last 30 seconds confirms an active microphone; otherwise it directs you to start on the nursery iPhone. The separate Stop microphone action on the Listener asks for confirmation before fully releasing the microphone. Standby continues microphone power use and its privacy indicator; interruption or app termination may require reopening the nursery app. Parent confirms the reported state and warns if a request cannot be verified.
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

On **iOS 26+**, **Parent Settings → System alarm test → Test alarm in 5 seconds** requests alarm permission and schedules one AlarmKit alarm five seconds after permission is granted. It uses the system alarm sound, which may sound on the iPhone even in Silent Mode or Focus. Wear the paired Watch to evaluate actual wrist alerts; watchOS controls vibration and delivery. Closing Settings or locking the phone leaves the alarm scheduled. Stop it in the system alert or return to Settings and choose **Cancel / stop test alarm**, including after relaunch. This manual test is independent of crying alerts, server pairing and Watch push testing. Older iOS versions show that iOS 26 is required.
