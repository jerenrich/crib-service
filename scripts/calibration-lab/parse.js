// Parses the Listener's sound-analysis CSV (SoundAnalysisLog.swift) into the
// event stream detector.js replays, plus compact series for charts.

// "2026-11-10T05:21:20.219Z" -> seconds since the epoch, without Date.parse.
export function isoSeconds(s) {
  if (!s || s.length < 20) return null;
  const ms = Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10), +s.slice(11, 13), +s.slice(14, 16), +s.slice(17, 19));
  let frac = 0;
  if (s[19] === '.') { const f = s.slice(20, s.indexOf('Z', 20)); frac = +f / 10 ** f.length; }
  return ms / 1000 + frac;
}

export const KIND = Object.freeze({ L: 1, C: 2, S: 3, X: 4, E: 5 });
// Classifier events other than scores (SoundAnalysisLog.swift), as codes in `events.type`.
export const EVENT = Object.freeze({ stop: 1, unavailable: 2, gap: 3, unmapped: 4 });
const EVENT_KINDS = {
  capture_stop: EVENT.stop, classifier_unavailable: EVENT.unavailable,
  classifier_gap: EVENT.gap, classifier_event_gap: EVENT.gap, classifier_result_unmapped: EVENT.unmapped,
};
const f64 = (a) => Float64Array.from(a);

function detailValue(detail, key) {
  const i = detail.indexOf(key + '=');
  if (i < 0) return null;
  const j = detail.indexOf(';', i);
  return detail.slice(i + key.length + 1, j < 0 ? undefined : j);
}

/**
 * Parse one or more CSV texts (in chronological order) and keep rows in
 * [from, to) seconds. Rows are kept in packed columns (a week of nights is
 * millions of rows); `order`/`at` give the replay order as (kind, index) pairs.
 * Level rows keep their raw capture frames: whether one continues the last is
 * decided by the detector, against the last sample it accepted, as the app does.
 * The latest capture_start before `from` is kept too, so the replay knows which
 * capture the night's first classifier scores belong to.
 * `runs` ({ runId: { threshold, policy } }, from the server's /api/runs) fills
 * in run markers logged outside these files.
 */
export function parseNight(texts, from = -Infinity, to = Infinity, { runs = {} } = {}) {
  const recordedAlerts = [], monitoring = [], caps = [], capIndex = new Map();
  const order = [], at = [];  // kind code, index into that kind's columns
  const L = { t: [], db: [], cap: [], sf: [], ef: [], sr: [] };
  const C = { t: [], ws: [], we: [], conf: [], ae: [], cap: [] };
  const S = { t: [], cap: [] }, X = { t: [] }, E = { t: [], type: [], cap: [], we: [] };
  let startBefore = null;  // [t, capture id] of the last capture_start before `from`
  const cap = (id) => { let i = capIndex.get(id); if (i === undefined) { i = caps.length; caps.push(id); capIndex.set(id, i); } return i; };
  const settingsSeen = new Map();
  // Each level row logs the settings it was judged with; keep where they change.
  // The classifier threshold is per run: a confidence_threshold marker when the
  // run logged one, else 0.80 for early time-coverage builds (which didn't).
  const changes = []; let lastKey = null;
  const runThreshold = new Map(), policyRuns = new Set();
  for (const text of texts) {
    let pos = 0;
    while (pos < text.length) {
      let nl = text.indexOf('\n', pos); if (nl < 0) nl = text.length;
      const line = text.slice(pos, nl); pos = nl + 1;
      if (!line || line.startsWith('recorded_at')) continue;
      const c = line.split(',');
      if (c.length < 19) continue;
      const kind = c[2];
      const t = isoSeconds(c[0]);
      if (t === null) continue;
      if (kind === 'run_start' || line.includes('confidence_threshold=')) {  // run markers, wherever they fall
        const detail = c.slice(18).join(',');
        const ct = detail.includes('confidence_threshold=') ? +detailValue(detail, 'confidence_threshold') : NaN;
        if (Number.isFinite(ct) && !runThreshold.has(c[1])) runThreshold.set(c[1], ct);
        if (kind === 'run_start' && detail.includes('alert_policy=')) policyRuns.add(c[1]);
      }
      if (t < from) {
        if (kind === 'capture_start') startBefore = [t, c[3]];
        else if ((kind === 'capture_stop' && startBefore?.[1] === c[3]) || kind === 'monitoring_stop' || kind === 'run_start') startBefore = null;
        continue;
      }
      if (t >= to) continue;
      if (startBefore) {  // first row in range: replay the capture that was already running
        order.push(KIND.S); at.push(S.t.length); S.t.push(startBefore[0]); S.cap.push(cap(startBefore[1]));
        startBefore = null;
      }
      const detail = c.slice(18).join(',');
      if (kind === 'level') {
        const db = +c[7];
        if (!Number.isFinite(db)) continue;
        // Native capture logs its PCM frames; old exports have none (cap = -1).
        const id = detailValue(detail, 'audio_capture_id');
        order.push(KIND.L); at.push(L.t.length);
        L.t.push(t); L.db.push(db);
        if (id) {
          L.cap.push(cap(id)); L.sf.push(+detailValue(detail, 'audio_start_frame'));
          L.ef.push(+detailValue(detail, 'audio_end_frame')); L.sr.push(+detailValue(detail, 'audio_sample_rate'));
        } else { L.cap.push(-1); L.sf.push(NaN); L.ef.push(NaN); L.sr.push(NaN); }
        const key = `${c[8]}|${c[14]}|${c[15]}`;
        settingsSeen.set(key, (settingsSeen.get(key) ?? 0) + 1);
        if (key + c[1] !== lastKey && c[8] !== '' && Number.isFinite(+c[8])) {
          lastKey = key + c[1];
          changes.push({ i: L.t.length - 1, t, run: c[1], threshold: +c[8], alertDuration: +c[14] || 5, quietResetDuration: +c[15] || 20 });
        }
        if (c[11] === '1') {
          // Builds before the time-coverage policy (before ~6 Nov 2026) did not tag alerts.
          const legacy = !detail.includes('alert_policy=');
          recordedAlerts.push({ t, trigger: detailValue(detail, 'alert_trigger') ?? 'volume', legacy });
        }
      } else if (kind === 'classification') {
        const conf = +c[6], ws = isoSeconds(c[4]), we = isoSeconds(c[5]);
        if (!Number.isFinite(conf) || ws === null || we === null) continue;
        const ae = isoSeconds(detailValue(detail, 'audio_window_end_at'));
        order.push(KIND.C); at.push(C.t.length);
        C.t.push(t); C.ws.push(ws); C.we.push(we); C.conf.push(conf); C.ae.push(ae ?? NaN); C.cap.push(cap(c[3]));
        if (c[11] === '1') recordedAlerts.push({ t, trigger: 'classifier' });
      } else if (kind in EVENT_KINDS) {
        order.push(KIND.E); at.push(E.t.length);
        E.t.push(t); E.type.push(EVENT_KINDS[kind]); E.cap.push(c[3] ? cap(c[3]) : -1); E.we.push(isoSeconds(c[5]) ?? NaN);
      } else if (kind === 'capture_start') {
        order.push(KIND.S); at.push(S.t.length); S.t.push(t); S.cap.push(cap(c[3]));
      } else if (kind === 'monitoring_stop' || kind === 'run_start') {
        order.push(KIND.X); at.push(X.t.length); X.t.push(t);
        monitoring.push({ t, kind });
      } else if (kind === 'monitoring_start') {
        monitoring.push({ t, kind });
      }
    }
  }
  for (const ch of changes) {
    const known = runs[ch.run], threshold = runThreshold.get(ch.run) ?? known?.threshold ?? null;
    const policy = policyRuns.has(ch.run) || !!known?.policy;
    // null: the run's threshold is unknown, so the replay uses the configured one.
    ch.classifierThreshold = threshold ?? (policy ? 0.8 : null);
    delete ch.run;
  }
  let recordedSettings = null, best = 0;
  for (const [key, n] of settingsSeen) {
    if (n > best) {
      best = n; const [thr, dur, reset] = key.split('|').map(Number);
      recordedSettings = { threshold: thr, alertDuration: dur, quietResetDuration: reset };
    }
  }
  // Other settings used for more than a minute of this range.
  const otherSettings = [...settingsSeen].filter(([, n]) => n < best && n > 240).map(([key]) => {
    const [threshold, alertDuration] = key.split('|').map(Number);
    return { threshold, alertDuration };
  });
  return {
    recordedAlerts, recordedSettings, monitoring, otherSettings, caps, settingsChanges: changes,
    // Run markers seen in these texts, in the shape parseNight's `runs` option takes.
    runs: Object.fromEntries([...new Set([...runThreshold.keys(), ...policyRuns])]
      .map((r) => [r, { threshold: runThreshold.get(r) ?? null, policy: policyRuns.has(r) }])),
    legacy: recordedAlerts.some((a) => a.legacy),
    order: Uint8Array.from(order), at: Uint32Array.from(at),
    levels: { t: f64(L.t), db: f64(L.db), cap: Int32Array.from(L.cap), sf: f64(L.sf), ef: f64(L.ef), sr: f64(L.sr) },
    // `at` is the audio time a score describes (for charts); `t` is when it arrived.
    scores: { t: f64(C.t), ws: f64(C.ws), we: f64(C.we), conf: f64(C.conf), ae: f64(C.ae), cap: Uint32Array.from(C.cap),
      at: f64(C.t.map((t, i) => (Number.isNaN(C.ae[i]) ? t : C.ae[i]))) },
    starts: { t: f64(S.t), cap: Uint32Array.from(S.cap) }, stops: { t: f64(X.t) },
    events: { t: f64(E.t), type: Uint8Array.from(E.type), cap: Int32Array.from(E.cap), we: f64(E.we) },
  };
}
