// A background worker that owns some nights: it fetches and parses their logs,
// keeps the parsed columns, and runs simulations on request, so the page never
// blocks on either. The page gets a slim copy of each night for drawing.
import { parseNight } from './parse.js';
import { simulate } from './detector.js';

const nights = new Map();

async function fetchText(name) {
  const res = await fetch('/api/sound/' + encodeURIComponent(name));
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || res.statusText);
  return res.text();
}

// Run markers from all cached logs (a night's own files often miss its run's start).
let runsPromise = null;
function fetchRuns() {
  runsPromise ??= fetch('/api/runs').then((r) => (r.ok ? r.json() : {})).catch(() => ({}));
  return runsPromise;
}

self.onmessage = async ({ data: m }) => {
  try {
    if (m.type === 'load') {
      const [texts, runs] = await Promise.all([Promise.all(m.files.map(fetchText)), fetchRuns()]);
      const parsed = parseNight(texts, m.from, m.to, { runs });
      nights.set(m.id, parsed);
      const view = {
        levels: { t: parsed.levels.t.slice(), db: parsed.levels.db.slice() },
        scores: { at: parsed.scores.at.slice(), conf: parsed.scores.conf.slice() },
        recordedAlerts: parsed.recordedAlerts, recordedSettings: parsed.recordedSettings,
        otherSettings: parsed.otherSettings, legacy: parsed.legacy, settingsChanges: parsed.settingsChanges,
      };
      self.postMessage({ req: m.req, view },
        [view.levels.t.buffer, view.levels.db.buffer, view.scores.at.buffer, view.scores.conf.buffer]);
    } else if (m.type === 'sim') {
      const night = nights.get(m.id);
      if (!night) throw new Error('night not loaded');
      self.postMessage({ req: m.req, result: simulate(night, m.settings) });
    }
  } catch (err) {
    self.postMessage({ req: m.req, error: String(err?.message || err) });
  }
};
