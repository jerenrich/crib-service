// A JavaScript port of the Listener's alert logic, for replaying recorded
// sound-analysis logs with different settings. Mirrors:
//   ios/BabyCryMonitor/Monitoring/CryDetector.swift          (SoundEvidenceWindow, CryDetector)
//   ios/BabyCryMonitor/Monitoring/CryConfidenceDetector.swift (classifier detector)
//   ios/BabyCryMonitor/Monitoring/CrySessionManager.swift     (episodes and first alerts)
// Keep it in step with those files. All times are seconds (wall clock unless noted).

export const DEFAULTS = Object.freeze({
  threshold: -35,          // absoluteThreshold, dBFS
  alertDuration: 5,        // seconds of qualifying sound before an alert
  quietResetDuration: 20,  // seconds of quiet that end an episode
  requiredFraction: 0.8,   // SoundEvidenceWindow.requiredFraction
  classifierEnabled: true, // the app always runs the classifier trigger
  classifierThreshold: 0.6,
  // Experimental, not in the app: a volume alert also needs the classifier to
  // have scored at least gateMin within the last gateWindow seconds.
  gateEnabled: false,
  gateMin: 0.1,
  gateWindow: 10,
});

const RECENT_DURATION = 5;
const EPS = 1e-9;

class EvidenceWindow {
  constructor(fraction) { this.f = fraction; this.iv = []; this.head = 0; this.startedAt = null; this.endedAt = null; }
  // Trims to the last hour with a head index, exactly like the Swift (and in O(1)
  // amortised time: refiltering the array here made noisy nights take seconds).
  append(start, end, positive) {
    start = Math.max(start, this.endedAt ?? start);
    if (!(end > start)) return;
    if (this.startedAt === null) this.startedAt = start;
    const iv = this.iv, last = iv[iv.length - 1];
    if (last && last.e === start && last.p === positive) last.e = end;
    else iv.push({ s: start, e: end, p: positive });
    this.endedAt = end;
    const cutoff = end - 3600;
    while (this.head < iv.length && iv[this.head].e <= cutoff) this.head++;
    if (this.head > 1024) { iv.splice(0, this.head); this.head = 0; }
    if (this.head < iv.length && iv[this.head].s < cutoff) iv[this.head].s = cutoff;
  }
  positive(from, to) {
    let d = 0;
    for (let k = this.iv.length - 1; k >= this.head; k--) {
      const i = this.iv[k];
      if (i.e <= from) break;
      if (i.p) d += Math.max(0, Math.min(to, i.e) - Math.max(from, i.s));
    }
    return d;
  }
  qualifies(end, duration, onset) {
    if (this.startedAt === null || this.endedAt !== end || end - Math.max(this.startedAt, onset) < duration) return false;
    return this.positive(end - duration, end) + EPS >= duration * this.f && this.recent(end);
  }
  recent(end) {
    if (this.startedAt === null || this.endedAt !== end) return false;
    const d = Math.min(RECENT_DURATION, end - this.startedAt);
    if (!(d > 0)) return false;
    return this.positive(end - d, end) + EPS >= d * this.f;
  }
  sustains(start, end) {
    if (this.endedAt !== end || !(end > start)) return false;
    return this.positive(start, end) + EPS >= (end - start) * this.f;
  }
}

/// Volume detector (CryDetector.swift). `ws`/`we` are the PCM-clock window.
class VolumeDetector {
  constructor(fraction) { this.f = fraction; this.reset(); }
  reset() {
    this.state = 'quiet'; this.quietSince = null; this.cryStartedAt = null;
    this.frames = []; this.firstFrame = null; this.activeSince = null; this.lastTimestamp = null;
    this.evidence = new EvidenceWindow(this.f); this.evidenceThreshold = null;
    this.lastEvidenceTime = null; this.quietEvidenceSince = null; this.cryEvidenceSince = null;
    this.inputInterrupted = false;
  }
  accepts(s) { return this.lastTimestamp === null || s.t > this.lastTimestamp; }
  consume(s, cfg) {
    if (!this.accepts(s)) return;
    this.inputInterrupted = false;
    if (this.lastTimestamp !== null && !s.cont) { this.reset(); this.inputInterrupted = true; }
    const time = s.we, thr = cfg.threshold;
    if (this.evidenceThreshold !== thr) { this.evidence = new EvidenceWindow(this.f); this.evidenceThreshold = thr; }
    const loud = s.db >= thr;
    this.evidence.append(s.ws, s.we, loud);
    this.lastTimestamp = s.t; this.lastEvidenceTime = time;
    if (this.firstFrame === null) this.firstFrame = time;
    this.frames.push([time, loud]);
    while (this.frames.length && time - this.frames[0][0] >= 5) this.frames.shift();
    let loudCount = 0; for (const fr of this.frames) if (fr[1]) loudCount++;
    const proportion = loudCount / Math.max(1, this.frames.length);
    const renews = loud && (this.state !== 'crying' || this.evidence.recent(time));
    if (renews) {
      this.quietSince = null; this.quietEvidenceSince = null;
      if (this.activeSince === null) this.activeSince = time;
    } else {
      if (this.quietEvidenceSince === null) { this.quietEvidenceSince = time; this.quietSince = s.t; }
      if (time - this.quietEvidenceSince >= 1) this.activeSince = null;
    }
    switch (this.state) {
      case 'quiet':
        if (this.activeSince !== null && time - this.activeSince >= 2) this.state = 'possibleCry';
        break;
      case 'possibleCry':
        if (this.firstFrame !== null && time - this.firstFrame >= 4.75 && proportion >= 0.6 && loud) {
          this.cryEvidenceSince = this.activeSince ?? time;
          this.cryStartedAt = s.t - (time - this.cryEvidenceSince);
          this.state = 'crying';
        } else if (this.quietEvidenceSince !== null && time - this.quietEvidenceSince >= 1) this.state = 'quiet';
        break;
      case 'crying':
        if (this.quietEvidenceSince !== null && time - this.quietEvidenceSince >= cfg.quietResetDuration) {
          this.state = 'quiet'; this.cryStartedAt = null; this.cryEvidenceSince = null;
          this.frames = []; this.activeSince = null; this.firstFrame = time;
          this.evidence = new EvidenceWindow(this.f);
        }
    }
  }
  canAlert(now, cfg) {
    if (this.state !== 'crying' || this.quietSince !== null || this.cryEvidenceSince === null
      || this.lastEvidenceTime === null || this.lastTimestamp === null) return false;
    const age = now - this.lastTimestamp;
    if (age < -1 || age > 2) return false;
    return this.evidence.qualifies(this.lastEvidenceTime, cfg.alertDuration, this.cryEvidenceSince);
  }
}

/// Classifier detector (CryConfidenceDetector.swift), minus the input-health
/// paths the log cannot replay (dropped buffers, unmapped results).
class ConfidenceDetector {
  constructor(fraction) { this.f = fraction; this.reset(); }
  reset() {
    this.captureID = null; this.observationStartedAt = null; this.cryStartedAt = null; this.quietSince = null;
    this.retainsEpisode = false; this.lastWindowEnd = null; this.lastObservationAt = null;
    this.lastCapturedWindowEndAt = null; this.lastPositiveCapturedAt = null; this.run = null;
    this.confirmed = false; this.evidence = new EvidenceWindow(this.f); this.latestPositive = false; this.settled = false;
  }
  get state() { return this.confirmed ? 'crying' : this.observationStartedAt === null ? 'quiet' : 'possibleCry'; }
  interrupt(date) {
    this.observationStartedAt = null; this.evidence = new EvidenceWindow(this.f); this.latestPositive = false;
    if (this.retainsEpisode && this.quietSince === null) this.quietSince = date;
  }
  started(id, at) {
    if (id === this.captureID) return;
    this.interrupt(at); this.captureID = id;
    this.lastWindowEnd = null; this.lastObservationAt = null; this.lastCapturedWindowEndAt = null;
  }
  stopped(at) { this.interrupt(at); this.captureID = null; }
  result(c, now, cfg) {
    this.advance(now, cfg);
    if (c.cap !== this.captureID) this.started(c.cap, now);
    if (this.lastWindowEnd !== null && !(c.we > this.lastWindowEnd)) return;
    const dur = c.we - c.ws, capturedEnd = c.ae ?? c.we;
    const age = now - capturedEnd;
    // The app checks 4 s ± 0.1; older builds logged 2 s windows, so accept
    // any plausible length here rather than discard those nights.
    if (dur < 0.5 || dur > 10 || age < -1 || age > 3) { this.interrupt(now); return; }
    if (this.lastWindowEnd !== null && (c.we - this.lastWindowEnd > 1.5
      || (this.lastObservationAt !== null && now - this.lastObservationAt > 3))) {
      this.interrupt(this.lastCapturedWindowEndAt ?? now);
    }
    const evidenceStart = Math.max(c.ws, this.evidence.endedAt ?? c.ws);
    this.latestPositive = c.conf >= cfg.classifierThreshold;
    this.evidence.append(evidenceStart, c.we, this.latestPositive);
    this.lastWindowEnd = c.we; this.lastObservationAt = now; this.lastCapturedWindowEndAt = capturedEnd;
    if (this.latestPositive) {
      this.lastPositiveCapturedAt = capturedEnd;
      if (this.observationStartedAt === null) { this.observationStartedAt = c.ws; this.run = null; }
      if (!this.confirmed && (this.run === null || !this.evidence.sustains(this.run.evidenceStart, c.we))) {
        this.run = { windowStart: c.ws, evidenceStart };
      }
      if (this.evidence.recent(c.we)) { this.retainsEpisode = true; this.quietSince = null; this.settled = false; }
      else if (this.quietSince === null) this.quietSince = capturedEnd;
      const start = this.observationStartedAt;
      if (start !== null && this.evidence.qualifies(c.we, cfg.alertDuration, start)) {
        if (!this.confirmed) {
          const onset = Math.max(start, this.run?.windowStart ?? start);
          this.cryStartedAt = capturedEnd - (c.we - onset);
        }
        this.confirmed = true;
      }
    } else if (this.quietSince === null) this.quietSince = capturedEnd;
    this.advance(now, cfg);
  }
  advance(now, cfg) {
    if (this.lastCapturedWindowEndAt !== null && now - this.lastCapturedWindowEndAt > 3) this.interrupt(this.lastCapturedWindowEndAt);
    if (!this.settled && this.quietSince !== null && now - this.quietSince >= cfg.quietResetDuration) {
      this.confirmed = false; this.cryStartedAt = null; this.retainsEpisode = false;
      this.observationStartedAt = null; this.latestPositive = false; this.settled = true;
    }
    if (!this.confirmed && this.observationStartedAt !== null && this.lastPositiveCapturedAt !== null
      && now - this.lastPositiveCapturedAt >= cfg.quietResetDuration) this.observationStartedAt = null;
  }
  canAlert(now, cfg) {
    if (!this.confirmed || !this.latestPositive || this.quietSince !== null || this.observationStartedAt === null
      || this.lastWindowEnd === null || this.lastObservationAt === null || this.lastCapturedWindowEndAt === null) return false;
    const a = now - this.lastObservationAt, b = now - this.lastCapturedWindowEndAt;
    if (a < -1 || a > 3 || b < -1 || b > 3) return false;
    return this.evidence.qualifies(this.lastWindowEnd, cfg.alertDuration, this.observationStartedAt);
  }
}

/**
 * Replay one night parsed by parse.js (packed columns, replayed in log order).
 * Returns { alerts, episodes }. Each alert is the first alert of an episode;
 * the server's 5-second reminders are not simulated.
 */
export function simulate(night, settings) {
  const cfg = { ...DEFAULTS, ...settings };
  const vol = new VolumeDetector(cfg.requiredFraction);
  const cls = new ConfidenceDetector(cfg.requiredFraction);
  let current = null, lastObservedAt = null, lastVolumeInputAt = null, lastDetectionAt = null;
  const episodes = [], alerts = [];
  const recentScores = []; // [capturedEnd, conf] for the experimental gate

  const sessionState = () => {
    if (vol.state === 'crying' || cls.state === 'crying' || (current && cls.retainsEpisode)) return 'crying';
    if (vol.state === 'possibleCry' || cls.state === 'possibleCry') return 'possibleCry';
    return 'quiet';
  };
  const end = (at) => {
    if (!current) return;
    current.endedAt = Math.max(current.startedAt, at);
    episodes.push(current); current = null;
  };
  const record = (t) => { lastDetectionAt = Math.max(lastDetectionAt ?? t, t); };
  const expireVolume = (now) => {
    if (lastVolumeInputAt === null || now - lastVolumeInputAt <= 2) return;
    const last = lastVolumeInputAt; lastVolumeInputAt = null;
    if (!cls.retainsEpisode) end(Math.max(last, lastDetectionAt ?? last));
    vol.reset();
  };
  const gateOpen = (now) => {
    if (!cfg.gateEnabled) return true;
    for (let k = recentScores.length - 1; k >= 0; k--) {
      const [at, c] = recentScores[k];
      if (now - at > cfg.gateWindow) break;
      if (c >= cfg.gateMin) return true;
    }
    return false;
  };
  const reconcile = (now, volumeIsLoud) => {
    if (sessionState() !== 'crying') {
      if (current) {
        const quiet = [vol.quietSince, cls.quietSince].filter((x) => x !== null);
        end(quiet.length ? Math.max(...quiet) : now);
      }
      return;
    }
    const starts = [vol.state === 'crying' ? vol.cryStartedAt : null, cls.state === 'crying' ? cls.cryStartedAt : null]
      .filter((x) => x !== null);
    const start = starts.length ? Math.min(...starts) : now;
    if (!current) current = { startedAt: start, alertAt: null, trigger: null, maxDb: -Infinity, maxConf: 0 };
    if (current.alertAt === null && start < current.startedAt) current.startedAt = start;
    const volumeReady = volumeIsLoud && vol.canAlert(now, cfg) && gateOpen(now);
    const classifierReady = cfg.classifierEnabled && cls.canAlert(now, cfg);
    if (current.alertAt === null && (volumeReady || classifierReady)) {
      current.alertAt = now; current.trigger = volumeReady ? 'volume' : 'classifier';
      alerts.push(current);
    }
  };
  const suspend = () => {
    end(Math.max(lastObservedAt ?? -Infinity, lastDetectionAt ?? -Infinity));
    vol.reset(); cls.reset(); lastVolumeInputAt = null;
  };

  const L = night.levels, C = night.scores, S = night.starts, X = night.stops;
  const lv = { t: 0, db: 0, ws: 0, we: 0, cont: true };
  const sc = { t: 0, cap: 0, ws: 0, we: 0, conf: 0, ae: null };
  for (let n = 0; n < night.order.length; n++) {
    const i = night.at[n];
    switch (night.order[n]) {
      case 1: { // level
        lv.t = L.t[i]; lv.db = L.db[i]; lv.ws = L.ws[i]; lv.we = L.we[i]; lv.cont = L.cont[i] === 1;
        const e = lv;
        if (lastObservedAt !== null && e.t <= lastObservedAt) break;
        if (!vol.accepts(e)) break;
        cls.advance(e.t, cfg);
        expireVolume(e.t);
        vol.consume(e, cfg);
        if (vol.inputInterrupted && !cls.retainsEpisode) end(lastDetectionAt ?? lastVolumeInputAt ?? e.t);
        lastObservedAt = e.t; lastVolumeInputAt = e.t; record(e.t);
        reconcile(e.t, e.db >= cfg.threshold);
        if (current) current.maxDb = Math.max(current.maxDb, e.db);
        break;
      }
      case 2: { // classification
        sc.t = C.t[i]; sc.cap = C.cap[i]; sc.ws = C.ws[i]; sc.we = C.we[i]; sc.conf = C.conf[i];
        sc.ae = Number.isNaN(C.ae[i]) ? null : C.ae[i];
        const e = sc;
        cls.result(e, e.t, cfg);
        recentScores.push([e.ae ?? e.t, e.conf]);
        if (recentScores.length > 256) recentScores.splice(0, 128);
        if (e.ae !== null) record(Math.min(e.ae, e.t));
        expireVolume(e.t);
        reconcile(e.t, false);
        if (current) current.maxConf = Math.max(current.maxConf, e.conf);
        break;
      }
      case 3: cls.started(S.cap[i], S.t[i]); break; // capture_start
      case 4: suspend(); break;                     // monitoring_stop / run_start
    }
  }
  if (current) { current.endedAt = null; episodes.push(current); }
  return { alerts, episodes };
}
