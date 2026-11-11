# Calibration Lab

Replays the Listener's sound-analysis logs with different alert settings, so you
can see which alerts you would have had, listen to them, and label them.

```bash
python3 scripts/calibration-lab/server.py --device <listener UDID or name>
```

Then open http://127.0.0.1:8787. The server fetches logs and audio from the
phone with `xcrun devicectl` on demand and caches them in `data/` (git-ignored,
along with your labels in `data/labels.json`). A cached file that the phone was
still writing is fetched again once it changes, and files the phone has since
pruned stay available from the cache. Without the phone it works from the
cache. The server only answers requests addressed to 127.0.0.1 or localhost,
and nothing is sent anywhere else.

Labels are saved as individual changes. If the server is down, they are kept in
the browser and sent when it is back.

Using it:

- Scroll or pinch over the chart to zoom, drag to move, click to listen. Click
  an alert marker (▼ these settings, ▽ sent) to select it. The strip under the
  chart is the whole night: drag its box, or drag across it to zoom in.
- `[` / `]` step through alerts, `Space` plays the selected one, `C` / `N`
  label it as a cry or not, `←` / `→` move, `+` / `−` zoom, `0` whole night.
- Ticked nights count towards the totals and the Compare settings table.
- "Use the phone's own settings" replays each moment with the settings the
  phone logged then (including changes during the night, and each run's
  classifier threshold). Moving a slider switches to your own settings.

How it works:

- `detector.js` ports `CryDetector.swift`, `CryConfidenceDetector.swift` and the
  first-alert logic of `CrySessionManager.swift`. Keep it in step with them.
  Older nights ran an earlier build, and the page says so.
- After changing `detector.js` or the Swift detectors, run
  `node scripts/calibration-lab/validate.mjs`. It replays every cached log with
  the phone's own settings and fails if any alert sent by a run that logs PCM
  frames (6 Nov 2026 onwards) is missing, extra or more than 10 ms off, both
  across the whole cache and night by night as the page loads them. It
  catches changes to rules the cached nights exercise (coverage, recent
  activity), but not to cases they never hit, such as long classifier gaps.
- `parse.js` reads `SoundAnalysisLog.swift`'s CSV into packed columns.
- `engine.js` is a worker that loads nights and runs simulations; the page runs
  a few of them and caches results per night and settings, so the page itself
  never blocks on the replay.
- Server reminders (the 5-second repeats) are not simulated: each alert is the
  first one for its episode.
- "Volume alerts need classifier support" is an experiment, not an app setting.
