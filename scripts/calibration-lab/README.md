# Calibration Lab

Replays the Listener's sound-analysis logs with different alert settings, so you
can see which alerts you would have had, listen to them, and label them.

```bash
python3 scripts/calibration-lab/server.py --device <listener UDID or name>
```

Then open http://127.0.0.1:8787. The server fetches logs and audio from the
phone with `xcrun devicectl` on demand and caches them in `data/` (git-ignored,
along with your labels in `data/labels.json`). Without the phone it works from
the cache. Nothing is sent anywhere else.

Using it:

- Scroll or pinch over the chart to zoom, drag to move, click to listen. Click
  an alert marker (▼ these settings, ▽ sent) to select it. The strip under the
  chart is the whole night: drag its box, or drag across it to zoom in.
- `[` / `]` step through alerts, `Space` plays the selected one, `C` / `N`
  label it as a cry or not, `←` / `→` move, `+` / `−` zoom, `0` whole night.
- Ticked nights count towards the totals and the Compare settings table.

How it works:

- `detector.js` ports `CryDetector.swift`, `CryConfidenceDetector.swift` and the
  first-alert logic of `CrySessionManager.swift`. Keep it in step with them.
  Replaying 6–10 Nov 2026 with the recorded settings reproduced every alert
  sent under the current alert policy to the millisecond. Older nights ran an
  earlier build, and the page says so.
- `parse.js` reads `SoundAnalysisLog.swift`'s CSV into packed columns.
- `engine.js` is a worker that loads nights and runs simulations; the page runs
  a few of them and caches results per night and settings, so the page itself
  never blocks on the replay.
- Server reminders (the 5-second repeats) are not simulated: each alert is the
  first one for its episode.
- "Volume alerts need classifier support" is an experiment, not an app setting.
