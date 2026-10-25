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
4. **Get a tap on your wrist.** Alerts repeat every 5 seconds until you snooze one on your Watch or iPhone, or the Listener confirms the configured quiet period. The Snooze button clears crying notifications on that device and pauses crying alerts for your chosen interval; a countdown and Resume alerts control let you end the snooze early.

### Made for the night shift

- **One compact Nightstand layout on both phones.** Listener and Parent share a sound state, live chart, fixed notice area and monitoring controls that fit without scrolling at standard text sizes. Alerts, snooze and connection changes keep the same positions; Details opens alert actions, recovery and device information. Larger accessibility text can scroll. Monitor, Activity and Devices tabs keep the sound view separate from history and setup.
- **Your timing, your settings.** Adjust the sound threshold, how long to wait, and how much quiet resets the timer.
- **A check before bed.** A four-step guide takes you through pairing, Watch notification setup, a confirmed wrist test, and starting monitoring. Returning users get a short nightly check.
- **Control from either iPhone.** Start once with the nursery app open. Parent Pause enters Standby: the microphone stays active while sound samples are discarded without detection, storage or sharing. Resume remotely, including while the Listener is locked. Stop on the Listener fully releases the microphone. Standby continues microphone power use and its privacy indicator; interruption or app termination may require reopening the nursery app. Parent confirms the reported state and warns if a request cannot be verified.
- **Nursery status at a glance.** Parent shows the same live sound-level chart as the nursery iPhone, with a short network delay. Check monitoring, battery, and connection status from the Parent phone or Watch.
- **Private audio.** Sound is processed on the nursery iPhone. Audio is never recorded or uploaded. Numeric levels are relayed for the live chart without being saved by the connection service. No accounts, ads, or analytics SDKs.

### What you need

Two iPhones running **iOS 17+**, an **Apple Watch running watchOS 10+** paired with the Parent iPhone, and internet access. Install Crib Service on both phones and its companion on the Watch, then enable notifications and direct Watch alerts. Use the bedtime setup guide to check Sleep Focus and haptics, and confirm you can feel a test alert.

To build and run it yourself, follow the [developer setup guide](docs/developer-guide.md#xcode-and-iphone-setup), including the [backend setup](docs/developer-guide.md#cloudflare-deployment).

### A few important limits

Crib Service currently detects sustained sound levels, so other loud noises can trigger it and quiet crying can be missed. Watch alerts depend on connectivity, notification permissions, and Focus settings; waking a sleeper is not guaranteed. It is not a medical monitor or a substitute for adult supervision.

---

[Developer guide](docs/developer-guide.md) · [Device testing checklist](docs/readiness-validation.md) · [Privacy and diagnostics](docs/diagnostics-review.md)
