#!/usr/bin/env node
// Checks that detector.js still matches the app: replays every cached
// sound-analysis log with the settings the phone logged at each moment, and
// compares the alerts with the ones the phone actually sent.
//
//   node scripts/calibration-lab/validate.mjs [data/sound directory]
//
// Run the lab once first so the logs are cached. Exits non-zero if any alert
// from a run that logs PCM-framed levels (the current timing) is missing, extra
// or moved. Older runs used different logic and are reported, not checked.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseNight } from './parse.js';
import { simulate } from './detector.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = process.argv[2] ?? path.join(here, 'data', 'sound');
const files = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => /^sound-.*\.csv$/.test(f)) : [];
if (!files.length) { console.error(`No cached logs in ${dir}. Open the lab once to fetch them.`); process.exit(2); }
files.sort((a, b) => a.split('-')[4] - b.split('-')[4]);

const night = parseNight(files.map((f) => fs.readFileSync(path.join(dir, f), 'utf8')));
const runStartBefore = (t) => {
  let best = -Infinity;
  for (const m of night.monitoring) if (m.kind === 'run_start' && m.t <= t && m.t > best) best = m.t;
  return Number.isFinite(best) ? best : t;
};
// Strict check: runs that log PCM frames with each level (volume_timing=pcm_frames_v1),
// which is what the current detectors time volume by. Earlier current-policy runs
// timed volume by the clock and are only reported.
const firstFramed = night.levels.cap.findIndex((c) => c >= 0);
const firstTagged = night.recordedAlerts.find((a) => !a.legacy);
if (firstFramed < 0 || !firstTagged) { console.error('No runs from a current build in the cache.'); process.exit(2); }
const strictFrom = night.levels.t[firstFramed];  // a run's start row isn't always cached; the first framed row is
const policyFrom = Math.min(strictFrom, runStartBefore(firstTagged.t));

const replayed = simulate(night, { asRecorded: true }).alerts;
const TOLERANCE = 0.01;  // seconds
const iso = (t) => new Date(t * 1000).toISOString().replace('T', ' ').slice(0, 23);
function compare(from, to) {
  const sent = night.recordedAlerts.filter((a) => a.t >= from && a.t < to).map((a) => a.t);
  const sim = replayed.filter((a) => a.alertAt >= from && a.alertAt < to).map((a) => a.alertAt);
  const unmatched = (xs, ys) => xs.filter((x) => !ys.some((y) => Math.abs(x - y) < TOLERANCE));
  return { sent, sim, missing: unmatched(sent, sim), extra: unmatched(sim, sent) };
}
const report = (r) => {
  for (const t of r.missing) console.log(`  sent but not replayed: ${iso(t)}`);
  for (const t of r.extra) console.log(`  replayed but not sent: ${iso(t)}`);
};

if (policyFrom < strictFrom) {
  const early = compare(policyFrom, strictFrom);
  console.log(`Earlier current-policy runs (${iso(policyFrom)} to ${iso(strictFrom)}), for information: `
    + `${early.sent.length} sent, ${early.sim.length} replayed, ${early.sent.length - early.missing.length} match.`);
  report(early);
}
const r = compare(strictFrom, Infinity);
console.log(`Runs with PCM-framed levels from ${iso(strictFrom)} (${files.length} logs): ${r.sent.length} alerts sent, ${r.sim.length} replayed.`);
report(r);
if (r.missing.length || r.extra.length) { console.log('MISMATCH'); process.exit(1); }
console.log(`OK: every alert matches to within ${TOLERANCE * 1000} ms.`);
