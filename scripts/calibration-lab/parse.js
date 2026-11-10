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

export const KIND = Object.freeze({ L: 1, C: 2, S: 3, X: 4 });
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
 */
export function parseNight(texts, from = -Infinity, to = Infinity) {
  const recordedAlerts = [], monitoring = [], caps = [], capIndex = new Map();
  const order = [], at = [];  // kind code, index into that kind's columns
  const L = { t: [], db: [], ws: [], we: [], cont: [] };
  const C = { t: [], ws: [], we: [], conf: [], ae: [], cap: [] };
  const S = { t: [], cap: [] }, X = { t: [] };
  const cap = (id) => { let i = capIndex.get(id); if (i === undefined) { i = caps.length; caps.push(id); capIndex.set(id, i); } return i; };
  const settingsSeen = new Map();
  let prevWin = null, prevT = null;
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
      if (t === null || t < from || t >= to) continue;
      const detail = c.slice(18).join(',');
      if (kind === 'level') {
        const db = +c[7];
        if (!Number.isFinite(db)) continue;
        const cap = detailValue(detail, 'audio_capture_id');
        let ws, we, cont, win = null;
        if (cap) {
          const sf = +detailValue(detail, 'audio_start_frame'), ef = +detailValue(detail, 'audio_end_frame');
          const sr = +detailValue(detail, 'audio_sample_rate');
          win = { cap, sf, ef, sr }; ws = sf / sr; we = ef / sr;
          cont = !!prevWin && prevWin.cap === cap && prevWin.sr === sr && prevWin.ef === sf;
        } else {
          ws = prevT === null ? t - 0.25 : Math.max(prevT, t - 0.25); we = t; cont = prevWin === null;
        }
        if (prevT === null) cont = true;
        prevWin = win; prevT = t;
        order.push(KIND.L); at.push(L.t.length);
        L.t.push(t); L.db.push(db); L.ws.push(ws); L.we.push(we); L.cont.push(cont ? 1 : 0);
        const key = `${c[8]}|${c[14]}|${c[15]}`;
        settingsSeen.set(key, (settingsSeen.get(key) ?? 0) + 1);
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
    recordedAlerts, recordedSettings, monitoring, otherSettings, caps,
    legacy: recordedAlerts.some((a) => a.legacy),
    order: Uint8Array.from(order), at: Uint32Array.from(at),
    levels: { t: f64(L.t), db: f64(L.db), ws: f64(L.ws), we: f64(L.we), cont: Uint8Array.from(L.cont) },
    // `at` is the audio time a score describes (for charts); `t` is when it arrived.
    scores: { t: f64(C.t), ws: f64(C.ws), we: f64(C.we), conf: f64(C.conf), ae: f64(C.ae), cap: Uint32Array.from(C.cap),
      at: f64(C.t.map((t, i) => (Number.isNaN(C.ae[i]) ? t : C.ae[i]))) },
    starts: { t: f64(S.t), cap: Uint32Array.from(S.cap) }, stops: { t: f64(X.t) },
  };
}
