// A background worker that owns some nights: it fetches and parses their logs,
// keeps the parsed columns, and runs simulations on request, so the page never
// blocks on either. The page gets a slim copy of each night for drawing.
import { parseNight, resolveRunThresholds } from './parse.js';
import { simulate } from './detector.js';

const nights = new Map();  // id -> { parsed, from }
// Replay starts this long before the night, so an episode already under way at
// 18:00 is replayed as the phone saw it; results before the night are dropped.
const WARMUP = 1800;

async function fetchText(name) {
  const res = await fetch('/api/sound/' + encodeURIComponent(name));
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || res.statusText);
  return res.text();
}

// Run markers from all cached logs (a night's own files often miss its run's
// start). Fetched for each load, since the cache grows as nights load; the page
// sends a newer index later with {type: 'runs'}.
const fetchRuns = () => fetch('/api/runs').then((r) => (r.ok ? r.json() : {})).catch(() => ({}));

self.onmessage = async ({ data: m }) => {
  try {
    if (m.type === 'load') {
      const [texts, runs] = await Promise.all([Promise.all(m.files.map(fetchText)), fetchRuns()]);
      const parsed = parseNight(texts, m.from - WARMUP, m.to, { runs });
      nights.set(m.id, { parsed, from: m.from });
      const view = {
        levels: { t: parsed.levels.t.slice(), db: parsed.levels.db.slice() },
        scores: { at: parsed.scores.at.slice(), conf: parsed.scores.conf.slice() },
        recordedAlerts: parsed.recordedAlerts.filter((a) => a.t >= m.from), recordedSettings: parsed.recordedSettings,
        otherSettings: parsed.otherSettings, legacy: parsed.legacy, settingsChanges: parsed.settingsChanges,
      };
      self.postMessage({ req: m.req, view },
        [view.levels.t.buffer, view.levels.db.buffer, view.scores.at.buffer, view.scores.conf.buffer]);
    } else if (m.type === 'runs') {
      // Re-resolve each night's per-run classifier thresholds with a newer index.
      const changes = {};
      for (const [id, { parsed }] of nights) changes[id] = resolveRunThresholds(parsed.settingsChanges, parsed.runs, m.runs);
      self.postMessage({ req: m.req, changes });
    } else if (m.type === 'sim') {
      const night = nights.get(m.id);
      if (!night) throw new Error('night not loaded');
      const { alerts, episodes } = simulate(night.parsed, m.settings);
      const result = {
        alerts: alerts.filter((a) => a.alertAt >= night.from),
        episodes: episodes.filter((ep) => (ep.endedAt ?? Infinity) >= night.from),
      };
      self.postMessage({ req: m.req, result });
    }
  } catch (err) {
    self.postMessage({ req: m.req, error: String(err?.message || err) });
  }
};
