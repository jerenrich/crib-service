import { DEFAULTS } from './detector.js';

const $ = (id) => document.getElementById(id);
const NIGHT_START_HOUR = 18, NIGHT_END_HOUR = 11, BACKGROUND_NIGHTS = 10;
const SWEEPS = {
  threshold: { values: [-60, -55, -50, -45, -40, -35, -30, -25, -20, -15, -10], fmt: (v) => `${v} dBFS`, head: 'Threshold' },
  alertDuration: { values: [5, 10, 15, 20, 30, 45, 60, 120, 180, 300, 600], fmt: (v) => fmtDuration(v), head: 'Window' },
};
// Observation windows the app offers (SettingsView.swift), and the finer steps
// the slider walks when "Only values the app offers" is off.
const APP_DURATIONS = [5, 30, 60, 120, 180, 300, 600];
const ALL_DURATIONS = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 300, 450, 600];
const durationSteps = () => (state.appSteps ? APP_DURATIONS : ALL_DURATIONS);
const nearestIndex = (list, v) => list.reduce((best, x, i) => (Math.abs(x - v) < Math.abs(list[best] - v) ? i : best), 0);
const fmtDuration = (v) => (v < 60 ? `${v} s` : v % 60 ? `${Math.floor(v / 60)} min ${v % 60} s` : `${v / 60} min`);
const SETTING_KEYS = Object.keys(DEFAULTS);
const settingsKey = (s) => SETTING_KEYS.map((k) => s[k]).join('|');

const store = {
  get(key, fallback) { try { const v = localStorage.getItem('calib:' + key); return v === null ? fallback : JSON.parse(v); } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem('calib:' + key, JSON.stringify(value)); } catch { /* private mode */ } },
};

const state = {
  sound: [], audio: [], offline: false,
  nights: [],                 // [{ id, from, to, files, label }], newest first
  data: new Map(),            // id -> slim parsed night (for drawing and tables)
  loading: new Set(),
  excluded: new Set(store.get('excluded', [])),
  focus: store.get('focus', null),
  settings: { ...DEFAULTS, ...store.get('settings', {}) },
  appSteps: store.get('appSteps', true),
  labels: [],                 // [{ t, kind: 'cry' | 'noise' }]
  zoom: null,                 // [from, to] seconds, null = whole night
  selected: null,             // time of the selected alert
  sweepBy: store.get('sweepBy', 'threshold'),
  tab: store.get('tab', 'alerts'),
};

// ---------- formatting ----------
const timeFmt = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
const hmFmt = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', hour12: false });
const wdFmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric' });
const monFmt = new Intl.DateTimeFormat(undefined, { month: 'short' });
/// "Mon 9 → Tue 10 Nov": a night is named by the evening it starts and the morning it ends.
const nightLabel = (from, to) => `${wdFmt.format(from)} → ${wdFmt.format(to)} ${monFmt.format(to)}`;
const fmtTime = (s) => timeFmt.format(new Date(s * 1000));
const fmtHM = (s) => hmFmt.format(new Date(s * 1000));
function fmtSpan(s) {
  if (s < 90) return `${Math.round(s)} s`;
  if (s < 5400) return `${Math.round(s / 60)} min`;
  return `${(s / 3600).toFixed(s < 36000 ? 1 : 0)} h`;
}
function setStatus(text, warn = false) { $('status').textContent = text; $('status').className = warn ? 'warn' : ''; }

// ---------- server ----------
async function api(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || res.statusText);
  return res;
}

function buildNights() {
  if (!state.sound.length) return [];
  const first = state.sound[0].start, last = Date.now() / 1000;
  const nights = [];
  const d = new Date(first * 1000); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - 1);
  for (; d.getTime() / 1000 < last; d.setDate(d.getDate() + 1)) {
    const from = new Date(d); from.setHours(NIGHT_START_HOUR);
    const to = new Date(d); to.setDate(to.getDate() + 1); to.setHours(NIGHT_END_HOUR);
    const f = from.getTime() / 1000, t = to.getTime() / 1000;
    const files = state.sound.filter((file, i) => file.start < t && (state.sound[i + 1]?.start ?? last) > f);
    if (!files.length) continue;
    const id = `${from.getFullYear()}-${String(from.getMonth() + 1).padStart(2, '0')}-${String(from.getDate()).padStart(2, '0')}`;
    nights.push({ id, from: f, to: t, files, label: nightLabel(from, to) });
  }
  return nights.reverse();
}

// ---------- engines: parsing and simulation in background workers ----------
// Each night lives in one worker; simulations for it run there. Jobs are queued
// per worker (high = what is on screen, low = the comparison) and dropped if
// nobody wants their result any more.
const POOL = Math.max(1, Math.min(4, (navigator.hardwareConcurrency || 4) - 1));
const engines = Array.from({ length: POOL }, () => {
  const e = { worker: new Worker('./engine.js', { type: 'module' }), replies: new Map(), high: [], low: [], busy: false, nights: 0 };
  e.worker.onmessage = ({ data }) => {
    const r = e.replies.get(data.req); e.replies.delete(data.req);
    if (r) data.error ? r.reject(new Error(data.error)) : r.resolve(data);
  };
  e.worker.onerror = (ev) => { for (const r of e.replies.values()) r.reject(new Error(ev.message || 'worker failed')); e.replies.clear(); };
  return e;
});
let reqSeq = 0;
function send(e, msg) {
  return new Promise((resolve, reject) => { const req = ++reqSeq; e.replies.set(req, { resolve, reject }); e.worker.postMessage({ ...msg, req }); });
}

const owner = new Map();       // night id -> engine
// Bumped when the run index changes: replays "as recorded" depend on it.
let runsVersion = 0;
const cacheKey = (id, settings) => `${runsVersion}|${id}|${settingsKey(settings)}`;
const simCache = new Map();    // `${id}|${settingsKey}` -> result
const simPending = new Map();  // same key -> job
const shown = new Map();       // night id -> last result drawn (kept while the next one computes)

function remember(key, result) {
  if (simCache.size > 4000) simCache.delete(simCache.keys().next().value);
  simCache.set(key, result);
}
function simulateNight(id, settings, prio, isStale) {
  const key = cacheKey(id, settings);
  const hit = simCache.get(key);
  if (hit) return Promise.resolve(hit);
  let job = simPending.get(key);
  if (job) {
    job.stales.push(isStale);
    if (prio === 'high' && job.prio === 'low' && !job.sent) {
      const q = job.engine.low; q.splice(q.indexOf(job), 1); job.engine.high.push(job); job.prio = 'high';
    }
    return job.promise;
  }
  const e = owner.get(id);
  if (!e) return Promise.resolve(null);
  job = { key, id, settings: { ...settings }, prio, stales: [isStale], engine: e, sent: false };
  job.promise = new Promise((resolve) => { job.resolve = resolve; });
  simPending.set(key, job); e[prio].push(job); updateBusy(); pump(e);
  return job.promise;
}
function pump(e) {
  if (e.busy) return;
  let job;
  while ((job = e.high.shift() ?? e.low.shift())) {
    if (!job.stales.every((f) => f())) break;
    simPending.delete(job.key); job.resolve(null);
  }
  if (!job) { updateBusy(); return; }
  e.busy = true; job.sent = true;
  send(e, { type: 'sim', id: job.id, settings: job.settings })
    .then(({ result }) => { remember(job.key, result); job.resolve(result); }, () => job.resolve(null))
    .finally(() => { simPending.delete(job.key); e.busy = false; pump(e); });
}
function updateBusy() { $('busy').classList.toggle('on', simPending.size > 0 || state.loading.size > 0); }

/// The result for a night with the current settings, or the last one shown while it computes.
function resultFor(id) {
  const r = simCache.get(cacheKey(id, state.settings));
  if (r) { shown.set(id, r); return r; }
  return shown.get(id) ?? null;
}
const isFresh = (id) => simCache.has(cacheKey(id, state.settings));

// ---------- loading ----------
const loadingNow = new Map();
function loadNight(id, { quiet = false } = {}) {
  if (state.data.has(id)) return Promise.resolve(true);
  if (loadingNow.has(id)) return loadingNow.get(id);
  const night = state.nights.find((n) => n.id === id);
  if (!night) return Promise.resolve(false);
  const e = engines.reduce((a, b) => (b.nights < a.nights ? b : a)); e.nights++;
  state.loading.add(id); updateBusy(); renderNights();
  if (!quiet) setStatus(`Loading ${night.label}…`);
  const job = send(e, { type: 'load', id, files: night.files.map((f) => f.name), from: night.from, to: night.to })
    .then(({ view }) => {
      owner.set(id, e); state.data.set(id, { ...view, id, night });
      setStatus(statusLine(), state.offline);
      scheduleRunsSync();
      return true;
    }, (err) => {
      e.nights--;
      if (!quiet) setStatus(`Couldn't load ${night.label}: ${err.message}`, true);
      return false;
    })
    .finally(() => { state.loading.delete(id); loadingNow.delete(id); updateBusy(); });
  loadingNow.set(id, job);
  return job;
}
async function loadRecentInBackground() {
  const queue = state.nights.slice(0, BACKGROUND_NIGHTS).map((n) => n.id).filter((id) => !state.data.has(id));
  const next = async () => {
    for (let id; (id = queue.shift());) { if (await loadNight(id, { quiet: true })) refresh(); }
  };
  await Promise.all(engines.map(next));
}
// Each load caches more logs, which can reveal markers for runs that earlier
// nights belong to. When the server's run index changes, have the workers
// re-resolve their nights' classifier thresholds and replay again.
let lastRuns = null, runsTimer = null;
function scheduleRunsSync() { clearTimeout(runsTimer); runsTimer = setTimeout(syncRuns, 400); }
async function syncRuns() {
  let runs;
  try { runs = await (await api('/api/runs')).json(); } catch { return; }
  const key = JSON.stringify(runs);
  if (key === lastRuns) return;
  const first = lastRuns === null;
  lastRuns = key;
  const replies = await Promise.all(engines.map((e) => send(e, { type: 'runs', runs }).catch(() => null)));
  let changed = false;
  for (const reply of replies) {
    for (const [id, changes] of Object.entries(reply?.changes ?? {})) {
      const data = state.data.get(id); if (!data) continue;
      if (JSON.stringify(data.settingsChanges) !== JSON.stringify(changes)) { data.settingsChanges = changes; changed = true; }
    }
  }
  if (changed || !first) { runsVersion++; refresh(); }
}

function statusLine() {
  const n = state.data.size;
  return `${state.offline ? 'Phone not reachable, using cached logs' : 'Connected to the Listener'} · ${n} night${n === 1 ? '' : 's'} loaded`;
}

// Labels: each change is an operation ({op: 'set', t, kind} or {op: 'delete', t}).
// Unsent operations are kept in localStorage and sent one batch at a time, so a
// change made while the server is down survives a reload and lands later.
let pendingOps = store.get('pendingLabelOps', []), flushing = null;
function applyOps(labels, ops) {
  for (const op of ops) {
    labels = labels.filter((l) => Math.abs(l.t - op.t) > 1e-3);
    if (op.op === 'set') labels.push({ t: op.t, kind: op.kind });
  }
  return labels.sort((a, b) => a.t - b.t);
}
async function loadLabels() {
  let server = null;
  try { server = await (await api('/api/labels')).json(); } catch { /* offline: use the last copy */ }
  state.labels = applyOps(server ?? store.get('labels', []), pendingOps);
  store.set('labels', state.labels);
  if (pendingOps.length) flushLabels();
}
function changeLabels(op) {
  state.labels = applyOps(state.labels, [op]);
  pendingOps.push(op);
  store.set('labels', state.labels); store.set('pendingLabelOps', pendingOps);
  flushLabels();
}
const postOps = (ops) => fetch('/api/labels', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ops }) });
function flushLabels() {
  if (flushing) return flushing;
  flushing = (async () => {
    let rejected = 0;
    try {
      while (pendingOps.length) {
        // Send the queue in one batch; if the server refuses it, send the changes
        // one at a time so only the ones it refuses are dropped.
        const batch = pendingOps.slice();
        let res = await postOps(batch), sent = batch.length;
        if (res.status === 400) {
          sent = 1;
          res = await postOps(batch.slice(0, 1));
          if (res.status === 400) {  // this change can never be saved: drop it, keep the rest
            pendingOps = pendingOps.slice(1); store.set('pendingLabelOps', pendingOps);
            rejected++;
            continue;
          }
        }
        if (!res.ok) throw new Error(`saving labels failed: ${res.status}`);
        const saved = await res.json();
        pendingOps = pendingOps.slice(sent);
        store.set('pendingLabelOps', pendingOps);
        // The server's list, plus anything changed while this batch was in flight.
        state.labels = applyOps(saved, pendingOps); store.set('labels', state.labels);
      }
      if (rejected) {
        // Show the server's list again, without the refused changes.
        try { state.labels = applyOps(await (await api('/api/labels')).json(), pendingOps); store.set('labels', state.labels); } catch { /* next load */ }
        renderAll();
      }
      setStatus(rejected ? `${rejected} label change${rejected === 1 ? ' was' : 's were'} refused by the lab server and dropped` : statusLine(), rejected > 0 || state.offline);
    } catch {
      setStatus(`Labels not saved to the lab server yet (${pendingOps.length} change${pendingOps.length === 1 ? '' : 's'} kept in this browser)`
        + (rejected ? `; ${rejected} refused and dropped` : ''), true);
    } finally { flushing = null; }
  })();
  return flushing;
}
setInterval(() => { if (pendingOps.length) flushLabels(); }, 15000);

// ---------- refresh ----------
let gen = 0, renderQueued = false;
function scheduleRender() {
  if (renderQueued) return;
  renderQueued = true;
  const run = () => { renderQueued = false; renderAll(); };
  document.hidden ? setTimeout(run, 0) : requestAnimationFrame(run);
}
/// Draw from what is cached now, then compute what is missing (focus first).
function refresh() {
  const g = ++gen, settings = { ...state.settings }, stale = () => g !== gen;
  renderAll();
  const ids = [...state.data.keys()].sort((a, b) => (b === state.focus) - (a === state.focus));
  for (const id of ids) {
    if (isFresh(id)) continue;
    simulateNight(id, settings, 'high', stale).then((r) => { if (r && !stale()) scheduleRender(); });
  }
  scheduleSweep();
  setTimeout(warmAlertAudio, 0);
}
function renderAll() { renderNights(); renderCards(); renderEvents(); drawChart(); }

// ---------- analysis ----------
const includedIds = () => state.nights.map((n) => n.id).filter((id) => state.data.has(id) && !state.excluded.has(id));
function alertWindow(a) { return [a.startedAt - 3, Math.max(a.alertAt, a.endedAt ?? a.alertAt) + 3]; }
function labelsIn(from, to) { return state.labels.filter((l) => l.t >= from && l.t <= to); }
function labelNear(t, slack = 15) {
  let best = null;
  for (const l of state.labels) if (Math.abs(l.t - t) <= slack && (!best || Math.abs(l.t - t) < Math.abs(best.t - t))) best = l;
  return best;
}
function lowerBound(arr, x) { let lo = 0, hi = arr.length; while (lo < hi) { const m = (lo + hi) >> 1; if (arr[m] < x) lo = m + 1; else hi = m; } return lo; }

/// Rows for one night: every simulated alert, plus recorded alerts it no longer sends.
function rowsFor(id) {
  const data = state.data.get(id), res = resultFor(id);
  if (!data || !res) return [];
  const rows = [], used = new Set();
  for (const a of res.alerts) {
    const [w0, w1] = alertWindow(a);
    const rec = data.recordedAlerts.findIndex((r, i) => !used.has(i) && r.t >= w0 && r.t <= w1);
    if (rec >= 0) used.add(rec);
    rows.push({ t: a.alertAt, start: a.startedAt, status: rec >= 0 ? 'same' : 'new', trigger: a.trigger,
      label: labelsIn(w0, w1)[0] ?? null, recordedT: rec >= 0 ? data.recordedAlerts[rec].t : null });
  }
  data.recordedAlerts.forEach((r, i) => {
    if (!used.has(i)) rows.push({ t: r.t, start: null, status: 'gone', trigger: r.trigger, label: labelNear(r.t), recordedT: r.t });
  });
  for (const row of rows) Object.assign(row, peakAround(data, row.start ?? row.t - state.settings.alertDuration, row.t));
  return rows.sort((a, b) => a.t - b.t);
}
function peakAround(data, from, to) {
  let peak = -Infinity, conf = 0;
  const L = data.levels, S = data.scores;
  for (let i = lowerBound(L.t, from - 1); i < L.t.length && L.t[i] <= to + 1; i++) if (L.db[i] > peak) peak = L.db[i];
  for (let i = lowerBound(S.at, from - 1); i < S.at.length && S.at[i] <= to + 3; i++) if (S.conf[i] > conf) conf = S.conf[i];
  return { peak, conf };
}

/// Totals over nights for given settings (from the cache).
function score(ids, settings) {
  let alerts = 0, falseAlarms = 0, unlabeled = 0, cries = 0, caught = 0, missing = 0;
  for (const id of ids) {
    const res = settings ? simCache.get(cacheKey(id, settings)) : resultFor(id);
    if (!res) { missing++; continue; }
    const night = state.data.get(id).night, windows = res.alerts.map(alertWindow);
    alerts += res.alerts.length;
    for (const [w0, w1] of windows) {
      const ls = labelsIn(w0, w1);
      if (ls.some((l) => l.kind === 'cry')) continue;
      if (ls.some((l) => l.kind === 'noise')) falseAlarms++; else unlabeled++;
    }
    for (const l of state.labels) {
      if (l.kind !== 'cry' || l.t < night.from || l.t >= night.to) continue;
      cries++;
      if (windows.some(([w0, w1]) => l.t >= w0 && l.t <= w1)) caught++;
    }
  }
  return { alerts, falseAlarms, unlabeled, cries, caught, missing };
}

// ---------- nights ----------
function renderNights() {
  $('nights').innerHTML = state.nights.map((n) => {
    const data = state.data.get(n.id), res = data ? resultFor(n.id) : null;
    const count = state.loading.has(n.id) ? '<span class="spin"></span>'
      : res ? `${res.alerts.length} <span class="muted">/ ${data.recordedAlerts.length}</span>` : data ? '…' : '<span class="muted">–</span>';
    return `<div class="nrow${n.id === state.focus ? ' focus' : ''}" data-id="${n.id}">
      <input type="checkbox" ${state.excluded.has(n.id) ? '' : 'checked'} title="Count in totals">
      <span>${n.label}${data?.legacy ? '<span class="tag">older app</span>' : ''}</span>
      <span class="ncount${data && !isFresh(n.id) ? ' updating' : ''}">${count}</span></div>`;
  }).join('');
}
$('nights').addEventListener('click', (ev) => {
  const row = ev.target.closest('.nrow'); if (!row) return;
  const id = row.dataset.id;
  if (ev.target.matches('input')) {
    if (ev.target.checked) state.excluded.delete(id); else state.excluded.add(id);
    store.set('excluded', [...state.excluded]);
    loadNight(id).then(refresh);
  } else focusNight(id);
});
$('tickAll').onclick = () => { state.excluded.clear(); store.set('excluded', []); refresh(); };

async function focusNight(id) {
  if (state.focus !== id) { state.zoom = null; state.selected = null; }
  state.focus = id; store.set('focus', id);
  renderAll();
  await loadNight(id);
  if (state.focus !== id) return;
  const data = state.data.get(id);
  if (data?.recordedSettings && !store.get('settingsTouched', false)) useRecorded();
  syncControls();
  refresh();
}

// ---------- cards ----------
function renderCards() {
  const ids = includedIds(), t = score(ids);
  let sent = 0; for (const id of ids) sent += state.data.get(id).recordedAlerts.length;
  const stale = ids.some((id) => !isFresh(id));
  if (ids.length && t.missing === ids.length) {  // nothing computed yet
    $('cards').innerHTML = ['alerts with these settings', 'labelled cries caught', 'labelled false alarms', 'alerts still to label']
      .map((label) => `<div class="card updating"><div class="n">…</div><div class="t">${label}</div><div class="d"></div></div>`).join('');
    return;
  }
  const cards = [
    { n: t.alerts, t: 'alerts with these settings', d: `${sent} actually sent · ${ids.length} night${ids.length === 1 ? '' : 's'}` },
    { n: t.cries ? `${t.caught}/${t.cries}` : '–', t: 'labelled cries caught',
      d: !t.cries ? '<span class="muted">Label alerts to see this</span>' : t.caught < t.cries ? `<span style="color:var(--accent)">${t.cries - t.caught} missed</span>` : 'none missed' },
    { n: t.falseAlarms, t: 'labelled false alarms', d: '' },
    { n: t.unlabeled, t: 'alerts still to label', d: t.unlabeled ? '<span class="muted">Click for the next one ›</span>' : '', action: t.unlabeled ? 'nextUnlabelled' : '' },
  ];
  $('cards').innerHTML = cards.map((c) => `<div class="card${stale ? ' updating' : ''}${c.action ? ' action' : ''}" ${c.action ? `data-action="${c.action}"` : ''}>
    <div class="n">${c.n}</div><div class="t">${c.t}</div><div class="d">${c.d}</div></div>`).join('');
}
$('cards').addEventListener('click', (ev) => { if (ev.target.closest('[data-action="nextUnlabelled"]')) nextUnlabelled(); });

async function nextUnlabelled() {
  const order = includedIds(), start = Math.max(0, order.indexOf(state.focus));
  for (let k = 0; k < order.length; k++) {
    const id = order[(start + k) % order.length];
    const after = k === 0 && state.selected !== null ? state.selected + 0.5 : -Infinity;
    const row = rowsFor(id).find((r) => r.status !== 'gone' && !r.label && r.t > after);
    if (!row) continue;
    if (id !== state.focus) await focusNight(id);
    selectAlert(row);
    return;
  }
}

// ---------- alerts table ----------
let currentRows = [];
function renderEvents() {
  const id = state.focus, data = state.data.get(id), table = $('events');
  $('tabAlerts').textContent = data ? `Alerts · ${data.night.label}` : 'Alerts';
  if (!data) { currentRows = []; table.innerHTML = `<tr><td class="empty">${state.loading.has(id) ? 'Loading…' : 'Pick a night.'}</td></tr>`; return; }
  if (!resultFor(id)) { currentRows = []; table.innerHTML = '<tr><td class="empty">Working out the alerts…</td></tr>'; return; }
  const rows = currentRows = rowsFor(id);
  const gone = rows.filter((r) => r.status === 'gone').length, added = rows.filter((r) => r.status === 'new').length;
  const notes = [rows.length ? `${added} new, ${gone} no longer sent` : ''];
  if (data.legacy) notes.push('an older app build sent these, so they won’t all line up');
  if (data.otherSettings.length) notes.push(`settings changed during the night (also ${data.otherSettings.map((s) => `${s.threshold} dBFS / ${s.alertDuration} s`).join(', ')})`);
  table.dataset.note = notes.filter(Boolean).join(' · ');
  updateTabNote();
  if (!rows.length) { table.innerHTML = `<tr><td class="empty">No alerts with these settings, and none were sent.</td></tr>`; return; }
  const badge = { same: ['b-same', 'Alerts, as sent'], new: ['b-new', 'New alert'], gone: ['b-gone', 'No alert now'] };
  table.innerHTML = `<thead><tr><th></th><th>Time</th><th>With these settings</th><th>Trigger</th><th>Peak</th><th>Classifier</th><th>What was it?</th></tr></thead><tbody>${rows.map((r, i) => {
    const kind = r.label?.kind, sel = isSelected(r);
    return `<tr data-i="${i}" class="${sel ? 'sel' : ''}">
      <td><button class="play" data-play ${audioFor(r.t - 10) ? '' : 'disabled title="No audio saved for this time"'}>▶</button></td>
      <td class="mono">${fmtTime(r.t)}</td>
      <td><span class="badge ${badge[r.status][0]}">${badge[r.status][1]}</span></td>
      <td class="muted">${r.trigger}</td>
      <td class="mono">${Number.isFinite(r.peak) ? r.peak.toFixed(0) + ' dB' : '–'}</td>
      <td class="mono" style="color:${r.conf >= settingSegments(data, r.t, r.t + 1e-3, 'classifierThreshold')[0].thr ? 'var(--conf)' : 'inherit'}">${r.conf.toFixed(2)}</td>
      <td><span class="labels"><button data-l="cry" class="cry ${kind === 'cry' ? 'on' : ''}">Cry</button><button data-l="noise" class="noise ${kind === 'noise' ? 'on' : ''}">Not a cry</button></span></td>
    </tr>`;
  }).join('')}</tbody>`;
}
const isSelected = (r) => state.selected !== null && Math.abs(state.selected - r.t) < 0.5;
$('events').addEventListener('click', (ev) => {
  const tr = ev.target.closest('tbody tr[data-i]'); if (!tr) return;
  const r = currentRows[+tr.dataset.i];
  const lab = ev.target.closest('[data-l]'), play = ev.target.closest('[data-play]');
  if (lab) { setLabel(r, lab.dataset.l); return; }
  selectAlert(r, { scroll: false });
  if (play && !play.disabled) playAt(r.t - 10);
});

function setLabel(row, kind) {
  const existing = row.label;
  if (existing && existing.kind === kind) changeLabels({ op: 'delete', t: existing.t });
  else changeLabels({ op: 'set', t: existing ? existing.t : row.recordedT ?? row.t, kind });
  renderAll(); scheduleSweep(0);
}

function selectAlert(row, { scroll = true, zoom = true } = {}) {
  state.selected = row.t;
  if (zoom) {
    const start = row.start ?? row.t - 20, pad = Math.max(15, (row.t - start) * 0.4);
    const [v0, v1] = currentView() ?? [0, 0];
    // Keep the zoom if the alert already sits comfortably in view at a useful scale.
    if (!(start > v0 && row.t < v1 && v1 - v0 < 900)) animateTo(start - pad - 10, row.t + pad + 20);
  }
  renderEvents(); drawChart();
  if (scroll) document.querySelector('#events tr.sel')?.scrollIntoView({ block: 'nearest' });
}
function stepAlert(dir) {
  const rows = currentRows; if (!rows.length) return;
  // With nothing selected, step from what is on screen.
  const view = currentView(), mid = view ? (view[0] + view[1]) / 2 : null;
  const cur = state.selected ?? (state.zoom && mid !== null ? mid : dir > 0 ? -Infinity : Infinity);
  const row = dir > 0 ? rows.find((r) => r.t > cur + 0.5) : [...rows].reverse().find((r) => r.t < cur - 0.5);
  if (row) selectAlert(row);
}
$('prevAlert').onclick = () => stepAlert(-1);
$('nextAlert').onclick = () => stepAlert(1);

// ---------- tabs ----------
function syncTabs() {
  document.querySelectorAll('.tabs .tab').forEach((b) => b.classList.toggle('on', b.dataset.tab === state.tab));
  $('paneAlerts').hidden = state.tab !== 'alerts'; $('paneSweep').hidden = state.tab !== 'sweep';
  $('sweepBy').hidden = state.tab !== 'sweep';
  updateTabNote();
}
function updateTabNote() { $('tabNote').textContent = state.tab === 'alerts' ? ($('events').dataset.note ?? '') : ''; }
document.querySelectorAll('.tabs .tab').forEach((b) => {
  b.onclick = () => { state.tab = b.dataset.tab; store.set('tab', state.tab); syncTabs(); };
});

// ---------- chart ----------
const base = $('chart'), overlay = $('overlay'), tip = $('tip'), overview = $('overview');
const PAD = { l: 44, r: 14, t: 36, b: 22 }, CONF_H = 52, GAP = 12, DB_MIN = -70, DB_MAX = 0, MIN_SPAN = 10;
const MARK_Y = { sim: 10, sent: 25 };
const C = {};
function readColors() {
  const cs = getComputedStyle(document.documentElement);
  for (const k of ['muted', 'grid', 'ink', 'panel', 'wave', 'wave-loud', 'conf', 'accent', 'accent-soft', 'cry', 'noise', 'gap', 'font', 'soft']) C[k] = cs.getPropertyValue('--' + k).trim();
}
readColors();
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { readColors(); drawChart(); });

function fit(canvas) {
  const dpr = window.devicePixelRatio || 1, w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) { canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr); }
  const g = canvas.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, w, h);
  return [g, w, h];
}
function fullRange() {
  const data = state.data.get(state.focus);
  if (!data) return null;
  const L = data.levels.t;
  const f0 = L.length ? Math.max(data.night.from, L[0] - 600) : data.night.from;
  const f1 = Math.min(data.night.to, Math.max(L.length ? L[L.length - 1] + 300 : data.night.to, f0 + 3600));
  return [f0, f1];
}
function currentView() { const f = fullRange(); return f ? (state.zoom ?? f) : null; }
function clampView(a, b) {
  const [f0, f1] = fullRange(), total = f1 - f0;
  const span = Math.min(Math.max(b - a, MIN_SPAN), total);
  a = Math.min(Math.max(a, f0), f1 - span);
  return [a, a + span];
}
function setView(a, b) {
  if (!fullRange()) return;
  [a, b] = clampView(a, b);
  const [f0, f1] = fullRange();
  state.zoom = b - a >= f1 - f0 - 0.5 ? null : [a, b];
  scheduleDraw();
}
let anim = null;
function cancelAnim() { if (anim) cancelAnimationFrame(anim); anim = null; }
/// Glide to [a, b]: centre moves linearly, span changes geometrically.
function animateTo(a, b) {
  const from = currentView(); if (!from) return;
  const to = clampView(a, b);
  cancelAnim();
  if (document.hidden) { setView(...to); return; }
  const c0 = (from[0] + from[1]) / 2, c1 = (to[0] + to[1]) / 2, s0 = from[1] - from[0], s1 = to[1] - to[0], t0 = performance.now();
  const step = (now) => {
    const k = Math.min(1, (now - t0) / 240), e = 1 - (1 - k) ** 3;
    const s = s0 * (s1 / s0) ** e, c = c0 + (c1 - c0) * e;
    setView(c - s / 2, c + s / 2);
    anim = k < 1 ? requestAnimationFrame(step) : null;
  };
  anim = requestAnimationFrame(step);
}
function zoomAround(t, factor) {
  const [v0, v1] = currentView(), span = v1 - v0, f = (t - v0) / span, ns = span * factor;
  setView(t - f * ns, t - f * ns + ns);
}
function showSpan(span) {
  const f = fullRange(); if (!f) return;
  if (!span) { animateTo(f[0], f[1]); return; }
  const [v0, v1] = currentView();
  const c = playhead !== null && playhead >= v0 && playhead <= v1 ? playhead : state.selected !== null && state.selected >= v0 && state.selected <= v1 ? state.selected : (v0 + v1) / 2;
  animateTo(c - span / 2, c + span / 2);
}
document.querySelectorAll('#spans button').forEach((b) => { b.onclick = () => showSpan(+b.dataset.span); });

let drawQueued = false;
function scheduleDraw() {
  if (drawQueued) return;
  drawQueued = true;
  const run = () => { drawQueued = false; drawChart(); };
  document.hidden ? setTimeout(run, 0) : requestAnimationFrame(run);
}

/// A setting's value over [a, b]: one segment normally, or one per change the
/// phone made when replaying "as recorded". `key` is 'threshold' or
/// 'classifierThreshold' (null in a change: unknown for that run, so the
/// configured value applies, as in the replay).
function settingSegments(data, a, b, key = 'threshold') {
  const ch = data?.settingsChanges, mine = state.settings[key];
  if (!state.settings.asRecorded || !ch?.length) return [{ a, b, thr: mine }];
  let lo = 0, hi = ch.length;  // first change after a
  while (lo < hi) { const m = (lo + hi) >> 1; if (ch[m].t <= a) lo = m + 1; else hi = m; }
  const segs = [];
  for (let k = Math.max(0, lo - 1), from = a; k < ch.length && from < b; k++) {
    const to = Math.min(b, ch[k + 1]?.t ?? b);
    if (to > from) segs.push({ a: from, b: to, thr: ch[k][key] ?? mine });
    from = Math.max(from, to);
  }
  return segs.length ? segs : [{ a, b, thr: ch[ch.length - 1][key] ?? mine }];
}
const thresholdSegments = (data, a, b) => settingSegments(data, a, b, 'threshold');
/// Walks segments in time order: at(t) for increasing t, without searching again.
function segmentWalker(segs) {
  let k = 0;
  return (t) => { while (k < segs.length - 1 && segs[k].b <= t) k++; return segs[k].thr; };
}

let geo = null;  // geometry of the last base draw, for pointer handling and the overlay
function drawChart() {
  const [g, w, h] = fit(base);
  const data = state.data.get(state.focus), full = fullRange();
  g.font = `11px ${C.font}`;
  if (!data || !full) {
    geo = null; g.fillStyle = C.muted; g.fillText(state.loading.has(state.focus) ? 'Loading…' : 'Pick a night', PAD.l, 60);
    drawOverlay(); drawOverview(); return;
  }
  const [v0, v1] = currentView(), span = v1 - v0, plotW = w - PAD.l - PAD.r;
  const dbTop = PAD.t, dbH = h - PAD.t - PAD.b - CONF_H - GAP, confTop = dbTop + dbH + GAP;
  const x = (t) => PAD.l + ((t - v0) / span) * plotW;
  const yDb = (db) => dbTop + (1 - (Math.min(DB_MAX, Math.max(DB_MIN, db)) - DB_MIN) / (DB_MAX - DB_MIN)) * dbH;
  const yConf = (c) => confTop + (1 - c) * CONF_H;
  geo = { w, h, plotW, dbTop, dbH, confTop, v0, v1, x, inv: (px) => v0 + ((px - PAD.l) / plotW) * span };
  const res = resultFor(state.focus), segs = thresholdSegments(data, v0, v1), thr = segs[segs.length - 1].thr;
  $('chartTitle').innerHTML = `${data.night.label} <span class="muted">· ${fmtHM(v0)}–${fmtHM(v1)} · ${fmtSpan(span)}</span>`;
  document.querySelectorAll('#spans button').forEach((b) => {
    const s = +b.dataset.span; b.classList.toggle('on', s ? Math.abs(span - s) / s < 0.08 : !state.zoom);
  });

  // grid + axes
  g.strokeStyle = C.grid; g.lineWidth = 1; g.fillStyle = C.muted; g.textAlign = 'right'; g.textBaseline = 'middle';
  for (let db = DB_MIN; db <= DB_MAX; db += 10) {
    g.beginPath(); g.moveTo(PAD.l, yDb(db) + .5); g.lineTo(w - PAD.r, yDb(db) + .5); g.stroke();
    g.fillText(db, PAD.l - 6, yDb(db));
  }
  g.fillText('1.0', PAD.l - 6, yConf(1)); g.fillText('0', PAD.l - 6, yConf(0));
  g.strokeRect(PAD.l + .5, confTop + .5, plotW - 1, CONF_H - 1);
  const step = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200].find((s) => span / s <= Math.max(3, plotW / 85)) ?? 7200;
  g.textAlign = 'center'; g.textBaseline = 'top';
  for (let t = Math.ceil(v0 / step) * step; t <= v1; t += step) {
    const px = x(t); g.beginPath(); g.moveTo(px + .5, dbTop); g.lineTo(px + .5, confTop + CONF_H); g.stroke();
    g.fillText(step < 60 ? fmtTime(t) : fmtHM(t), px, h - PAD.b + 6);
  }

  g.save(); g.beginPath(); g.rect(PAD.l, 0, plotW, h); g.clip();
  // episodes that alerted: from cry start to alert
  if (res) {
    g.fillStyle = C['accent-soft'];
    for (const ep of res.episodes) {
      if (ep.alertAt === null) continue;
      const a = x(ep.startedAt), b = x(ep.alertAt);
      if (b >= PAD.l && a <= w - PAD.r) g.fillRect(a, dbTop, Math.max(1, b - a), dbH);
    }
  }
  // selected alert
  if (state.selected !== null) { g.fillStyle = C.soft; const px = x(state.selected); g.fillRect(px - 3, dbTop, 6, confTop + CONF_H - dbTop); }

  // sound level: per-pixel min/max columns, or a line when zoomed in close
  const L = data.levels;
  const i0 = Math.max(0, lowerBound(L.t, v0) - 1), i1 = Math.min(L.t.length, lowerBound(L.t, v1) + 1);
  const cols = Math.max(1, Math.floor(plotW)), yt = yDb(thr);
  const loudClip = () => { g.beginPath(); for (const sg of segs) g.rect(x(sg.a), dbTop, x(sg.b) - x(sg.a), yDb(sg.thr) - dbTop); g.clip(); };
  if (i1 - i0 < cols * 2) {
    const path = new Path2D(); let open = false;
    g.fillStyle = C.gap;
    for (let k = i0; k < i1; k++) {
      const gap = k > i0 && L.t[k] - L.t[k - 1] > 1;
      if (gap) g.fillRect(x(L.t[k - 1]), dbTop, Math.max(1, x(L.t[k]) - x(L.t[k - 1])), dbH);
      if (!open || gap) path.moveTo(x(L.t[k]), yDb(L.db[k])); else path.lineTo(x(L.t[k]), yDb(L.db[k]));
      open = true;
    }
    g.save(); g.beginPath(); g.rect(PAD.l, dbTop, plotW, dbH); g.clip();
    g.lineWidth = 1.5; g.lineJoin = 'round'; g.strokeStyle = C.wave; g.stroke(path);
    loudClip();
    g.strokeStyle = C['wave-loud']; g.stroke(path); g.restore();
  } else {
    let i = i0, prevT = null;
    const thrAt = segmentWalker(segs);
    const quiet = new Path2D(), loud = new Path2D();
    g.fillStyle = C.gap;
    for (let c = 0; c < cols && i < i1; c++) {
      const tEnd = v0 + ((c + 1) / cols) * span;
      let mn = Infinity, mx = -Infinity;
      while (i < i1 && L.t[i] < tEnd) {
        if (prevT !== null && L.t[i] - prevT > 5) g.fillRect(x(prevT), dbTop, Math.max(1, x(L.t[i]) - x(prevT)), dbH);
        prevT = L.t[i]; if (L.db[i] < mn) mn = L.db[i]; if (L.db[i] > mx) mx = L.db[i]; i++;
      }
      if (mx === -Infinity) continue;
      const px = PAD.l + c, top = yDb(mx), bot = Math.max(yDb(mn), top + 1);
      const cthr = thrAt(tEnd - span / cols / 2), cyt = yDb(cthr);
      if (mx >= cthr) {
        if (bot > cyt) quiet.rect(px, Math.max(top, cyt), 1, bot - Math.max(top, cyt));
        loud.rect(px, top, 1, Math.max(1, Math.min(bot, cyt) - top));
      } else quiet.rect(px, top, 1, bot - top);
    }
    g.fillStyle = C.wave; g.fill(quiet); g.fillStyle = C['wave-loud']; g.fill(loud);
  }
  // threshold line
  g.strokeStyle = C['wave-loud']; g.setLineDash([5, 4]); g.beginPath();
  segs.forEach((sg, k) => {
    const y = yDb(sg.thr) + .5;
    if (k) g.lineTo(x(sg.a), y); else g.moveTo(x(sg.a), y);
    g.lineTo(x(sg.b), y);
  });
  g.stroke(); g.setLineDash([]);

  // classifier lane
  const S = data.scores, csegs = settingSegments(data, v0, v1, 'classifierThreshold');
  const j0 = Math.max(0, lowerBound(S.at, v0) - 1), j1 = Math.min(S.at.length, lowerBound(S.at, v1) + 1);
  g.fillStyle = C.conf;
  if (j1 - j0 < cols / 4) {
    const bw = Math.max(2, (x(1) - x(0)) * 0.7), cthrAt = segmentWalker(csegs);
    for (let j = j0; j < j1; j++) {
      g.globalAlpha = S.conf[j] >= cthrAt(S.at[j]) ? 1 : 0.5;
      g.fillRect(x(S.at[j]) - bw, yConf(S.conf[j]), bw, Math.max(1, yConf(0) - yConf(S.conf[j])));
    }
  } else {
    let j = j0;
    const cthrAt = segmentWalker(csegs);
    for (let c = 0; c < cols && j < j1; c++) {
      const tEnd = v0 + ((c + 1) / cols) * span; let mx = -1;
      while (j < j1 && S.at[j] < tEnd) { if (S.conf[j] > mx) mx = S.conf[j]; j++; }
      if (mx < 0) continue;
      g.globalAlpha = mx >= cthrAt(tEnd - span / cols / 2) ? 1 : 0.5;
      g.fillRect(PAD.l + c, yConf(mx), 1, Math.max(1, yConf(0) - yConf(mx)));
    }
  }
  g.globalAlpha = 1;
  g.strokeStyle = C.conf; g.setLineDash([3, 3]); g.beginPath();
  csegs.forEach((sg, k) => {
    const y = yConf(sg.thr) + .5;
    if (k) g.lineTo(x(sg.a), y); else g.moveTo(x(sg.a), y);
    g.lineTo(x(sg.b), y);
  });
  g.stroke(); g.setLineDash([]);

  // alert markers
  const colorFor = (t0, t1) => {
    const ls = labelsIn(t0, t1);
    return ls.some((l) => l.kind === 'cry') ? C.cry : ls.some((l) => l.kind === 'noise') ? C.noise : C.accent;
  };
  const mark = (t, y, filled, color) => {
    const px = x(t); if (px < PAD.l - 6 || px > w - PAD.r + 6) return;
    g.beginPath(); g.moveTo(px, y + 5); g.lineTo(px - 5, y - 4); g.lineTo(px + 5, y - 4); g.closePath();
    if (filled) { g.fillStyle = color; g.fill(); } else { g.strokeStyle = color; g.lineWidth = 1.5; g.stroke(); g.lineWidth = 1; }
  };
  if (res) for (const a of res.alerts) {
    const [w0, w1] = alertWindow(a), col = colorFor(w0, w1), px = x(a.alertAt);
    mark(a.alertAt, MARK_Y.sim, true, col);
    g.strokeStyle = col; g.globalAlpha = .45; g.beginPath(); g.moveTo(px + .5, dbTop); g.lineTo(px + .5, dbTop + dbH); g.stroke(); g.globalAlpha = 1;
  }
  for (const r of data.recordedAlerts) mark(r.t, MARK_Y.sent, false, colorFor(r.t - 15, r.t + 15));
  g.restore();
  // threshold label (outside the clip so it is never cut)
  {
    const label = `${thr} dBFS`, tw = g.measureText(label).width, lx = w - PAD.r - tw - 6, ly = yt - 9;
    g.fillStyle = C.panel; g.fillRect(lx - 3, ly - 7, tw + 6, 14);
    g.fillStyle = C['wave-loud']; g.textAlign = 'left'; g.textBaseline = 'middle'; g.fillText(label, lx, ly);
  }
  drawOverlay(); drawOverview();
}

// Hover line, drag selection and playhead live on their own canvas, so moving
// the mouse or playing audio never redraws the data.
let hoverX = null, drag = null, playhead = null;
function drawOverlay() {
  const [g] = fit(overlay);
  if (!geo) return;
  const { x, dbTop, confTop, w } = geo, bottom = confTop + CONF_H;
  if (drag?.mode === 'zoom' && drag.x1 !== undefined) {
    g.fillStyle = C.ink; g.globalAlpha = .1; g.fillRect(Math.min(drag.x0, drag.x1), dbTop, Math.abs(drag.x1 - drag.x0), bottom - dbTop); g.globalAlpha = 1;
  }
  if (hoverX !== null && hoverX >= PAD.l && hoverX <= w - PAD.r && !drag?.moved) {
    g.strokeStyle = C.muted; g.beginPath(); g.moveTo(hoverX + .5, dbTop); g.lineTo(hoverX + .5, bottom); g.stroke();
  }
  if (playhead !== null) {
    const px = x(playhead);
    if (px >= PAD.l && px <= w - PAD.r) { g.strokeStyle = C.ink; g.lineWidth = 2; g.beginPath(); g.moveTo(px, dbTop - 4); g.lineTo(px, bottom); g.stroke(); }
  }
}

function nearestValue(arr, vals, t, maxGap) {
  const k = lowerBound(arr, t); let best = null;
  for (const m of [k - 1, k]) if (m >= 0 && m < arr.length && Math.abs(arr[m] - t) <= maxGap && (best === null || Math.abs(arr[m] - t) < Math.abs(arr[best] - t))) best = m;
  return best === null ? null : vals[best];
}
/// The alert marker under (px, py), if any: { t, row }.
function markerAt(px, py) {
  if (!geo || py > PAD.t - 2) return null;
  let best = null;
  for (const r of currentRows) {
    const d = Math.abs(geo.x(r.t) - px);
    if (d < 8 && (!best || d < best.d)) best = { d, row: r };
  }
  return best?.row ?? null;
}
function showTip(px, py) {
  const data = state.data.get(state.focus);
  if (!geo || !data || px < PAD.l || px > geo.w - PAD.r) { tip.style.display = 'none'; return; }
  const marker = markerAt(px, py);
  let text;
  if (marker) {
    const what = { same: 'Alert, as sent', new: 'New alert', gone: 'Sent, no alert now' }[marker.status];
    text = `${fmtTime(marker.t)}  ${what}\n${marker.trigger}${marker.label ? ' · ' + (marker.label.kind === 'cry' ? 'cry' : 'not a cry') : ''} · click to select`;
  } else {
    const t = geo.inv(px);
    const db = nearestValue(data.levels.t, data.levels.db, t, 1), c = nearestValue(data.scores.at, data.scores.conf, t, 2);
    text = `${fmtTime(t)}  ${db === null ? '—' : db.toFixed(1) + ' dB'}${c === null ? '' : '  p=' + c.toFixed(2)}${audioFor(t) ? '\nclick to listen' : ''}`;
  }
  tip.textContent = text; tip.style.display = 'block';
  const left = px + 14 + tip.offsetWidth > geo.w ? px - 14 - tip.offsetWidth : px + 14;
  tip.style.left = left + 'px'; tip.style.top = (marker ? PAD.t + 4 : PAD.t + 8) + 'px';
  overlay.classList.toggle('pointing', !!marker);
}

// ---- pointer: drag to move, shift-drag to zoom to a range, pinch to zoom, click to select/listen ----
const pointers = new Map();
let pinch = null;
overlay.addEventListener('pointerdown', (e) => {
  if (!geo) return;
  overlay.setPointerCapture(e.pointerId); pointers.set(e.pointerId, e.offsetX); cancelAnim();
  if (pointers.size === 2) {
    const [a, b] = [...pointers.values()];
    pinch = { dist: Math.max(10, Math.abs(a - b)), view: currentView(), mid: geo.inv((a + b) / 2), fmid: ((a + b) / 2 - PAD.l) / geo.plotW };
    drag = null; return;
  }
  drag = { x0: e.offsetX, y0: e.offsetY, view: currentView(), mode: e.shiftKey ? 'zoom' : 'pan', moved: false };
});
overlay.addEventListener('pointermove', (e) => {
  if (!geo) return;
  if (pointers.has(e.pointerId)) pointers.set(e.pointerId, e.offsetX);
  if (pinch && pointers.size === 2) {
    const [a, b] = [...pointers.values()], span = (pinch.view[1] - pinch.view[0]) * pinch.dist / Math.max(10, Math.abs(a - b));
    const start = pinch.mid - pinch.fmid * span; setView(start, start + span); return;
  }
  hoverX = e.offsetX;
  if (drag) {
    if (Math.abs(e.offsetX - drag.x0) > 4) drag.moved = true;
    if (drag.mode === 'zoom') drag.x1 = e.offsetX;
    else if (drag.moved) {
      const [v0, v1] = drag.view, dt = -((e.offsetX - drag.x0) / geo.plotW) * (v1 - v0);
      overlay.classList.add('grabbing'); tip.style.display = 'none';
      setView(v0 + dt, v1 + dt); return;
    }
  } else showTip(e.offsetX, e.offsetY);
  overlay.classList.toggle('zooming', e.shiftKey && !drag);
  drawOverlay();
});
overlay.addEventListener('pointerleave', () => { hoverX = null; tip.style.display = 'none'; drawOverlay(); });
function endPointer(e) {
  pointers.delete(e.pointerId);
  if (pinch) { if (pointers.size < 2) pinch = null; drag = null; return; }
  if (!drag) return;
  const d = drag; drag = null; overlay.classList.remove('grabbing');
  if (e.type === 'pointercancel') { drawOverlay(); return; }
  if (d.mode === 'zoom' && Math.abs(e.offsetX - d.x0) > 6) {
    animateTo(geo.inv(Math.min(d.x0, e.offsetX)), geo.inv(Math.max(d.x0, e.offsetX)));
  } else if (!d.moved) {
    const marker = markerAt(d.x0, d.y0);
    if (marker) selectAlert(marker);
    else { const t = geo.inv(d.x0); if (audioFor(t)) playAt(t, { follow: false }); }
  }
  drawOverlay();
}
overlay.addEventListener('pointerup', endPointer);
overlay.addEventListener('pointercancel', endPointer);

// ---- wheel: scroll/pinch zooms around the pointer, sideways scroll moves ----
overlay.addEventListener('wheel', (e) => {
  if (!geo) return;
  e.preventDefault(); cancelAnim();
  const unit = e.deltaMode === 1 ? 33 : e.deltaMode === 2 ? 600 : 1;
  const dx = e.deltaX * unit, dy = e.deltaY * unit;
  if (!e.ctrlKey && Math.abs(dx) > Math.abs(dy)) {
    const [v0, v1] = currentView(), d = (dx / geo.plotW) * (v1 - v0);
    setView(v0 + d, v1 + d);
  } else {
    const k = e.ctrlKey ? 0.012 : 0.003;  // pinch gestures report small deltas; a wheel notch is ~100
    zoomAround(geo.inv(e.offsetX), Math.exp(Math.max(-400, Math.min(400, dy)) * k));
  }
  tip.style.display = 'none';
}, { passive: false });

// ---- keyboard ----
window.addEventListener('keydown', (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const tag = e.target.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
  const view = currentView();
  const sel = currentRows.find(isSelected);
  switch (e.key) {
    case 'ArrowLeft': case 'ArrowRight': {
      if (!view) return;
      const d = (view[1] - view[0]) * (e.shiftKey ? 0.8 : 0.2) * (e.key === 'ArrowLeft' ? -1 : 1);
      animateTo(view[0] + d, view[1] + d); break;
    }
    case '+': case '=': if (view) animateTo(...scaleView(view, 0.5)); break;
    case '-': case '_': if (view) animateTo(...scaleView(view, 2)); break;
    case '0': showSpan(0); break;
    case '[': case 'k': stepAlert(-1); break;
    case ']': case 'j': stepAlert(1); break;
    case 'c': if (sel) setLabel(sel, 'cry'); break;
    case 'n': if (sel) setLabel(sel, 'noise'); break;
    case ' ':
      if (tag === 'BUTTON') return;
      if (segment) audio.paused ? audio.play() : audio.pause();
      else if (sel && audioFor(sel.t - 10)) playAt(sel.t - 10);
      else return;
      break;
    default: return;
  }
  e.preventDefault();
});
function scaleView([v0, v1], f) { const c = (v0 + v1) / 2, s = (v1 - v0) * f; return [c - s / 2, c + s / 2]; }
window.addEventListener('keyup', (e) => { if (e.key === 'Shift') overlay.classList.remove('zooming'); });
new ResizeObserver(() => drawChart()).observe(base);

// ---- overview strip: the whole night, with the visible part boxed ----
const envelopes = new WeakMap();
function envelopeOf(data, f0, f1, bins) {
  const hit = envelopes.get(data);
  if (hit && hit.bins === bins && hit.f0 === f0 && hit.f1 === f1) return hit.max;
  const max = new Float32Array(bins).fill(-Infinity), L = data.levels, k = bins / (f1 - f0);
  for (let i = 0; i < L.t.length; i++) {
    const c = Math.floor((L.t[i] - f0) * k);
    if (c >= 0 && c < bins && L.db[i] > max[c]) max[c] = L.db[i];
  }
  envelopes.set(data, { bins, f0, f1, max });
  return max;
}
let ovMap = null;
function drawOverview() {
  const [g, w, h] = fit(overview);
  const data = state.data.get(state.focus), full = fullRange();
  if (!data || !full) { ovMap = null; return; }
  const [f0, f1] = full, total = f1 - f0, plotW = w - PAD.l - PAD.r, barsH = h - 14;
  const bins = Math.max(50, Math.floor(plotW)), max = envelopeOf(data, f0, f1, bins);
  const px = (t) => PAD.l + ((t - f0) / total) * plotW;
  const yOf = (db) => barsH * (1 - (Math.min(DB_MAX, Math.max(DB_MIN, db)) - DB_MIN) / (DB_MAX - DB_MIN));
  g.globalAlpha = .6;
  const thrAt = segmentWalker(thresholdSegments(data, f0, f1));
  for (let c = 0; c < bins; c++) {
    if (max[c] === -Infinity) continue;
    g.fillStyle = max[c] >= thrAt(f0 + (c + .5) * total / bins) ? C['wave-loud'] : C.wave;
    const y = yOf(max[c]); g.fillRect(PAD.l + (c / bins) * plotW, y, plotW / bins + .5, barsH - y);
  }
  g.globalAlpha = 1;
  const res = resultFor(state.focus);
  if (res) { g.fillStyle = C.accent; for (const a of res.alerts) g.fillRect(px(a.alertAt) - 1, 0, 2, 6); }
  g.fillStyle = C.muted; g.font = `10px ${C.font}`; g.textAlign = 'center'; g.textBaseline = 'alphabetic';
  const step = total > 8 * 3600 ? 7200 : 3600;
  for (let t = Math.ceil(f0 / step) * step; t < f1; t += step) { g.fillText(fmtHM(t), px(t), h - 1); g.fillRect(px(t), barsH, 1, 3); }
  const [v0, v1] = currentView(), xa = px(v0), xb = Math.max(px(v1), xa + 4);
  if (state.zoom) {
    g.fillStyle = C.panel; g.globalAlpha = .55;
    g.fillRect(PAD.l, 0, Math.max(0, xa - PAD.l), barsH); g.fillRect(xb, 0, Math.max(0, PAD.l + plotW - xb), barsH);
    g.globalAlpha = 1;
    g.strokeStyle = C.ink; g.lineWidth = 1.5; g.strokeRect(xa + .75, .75, xb - xa - 1.5, barsH - 1.5);
    g.fillStyle = C.ink; g.fillRect(xa - 1, barsH / 2 - 6, 3, 12); g.fillRect(xb - 2, barsH / 2 - 6, 3, 12);  // grips
  }
  if (playhead !== null && playhead >= f0 && playhead <= f1) { g.fillStyle = C.ink; g.fillRect(px(playhead) - 1, 0, 2, barsH); }
  ovMap = { f0, total, plotW, xa, xb, t: (x) => f0 + ((x - PAD.l) / plotW) * total };
}
let ovDrag = null;
overview.addEventListener('pointerdown', (e) => {
  if (!ovMap) return;
  cancelAnim();
  const m = ovMap, x = e.offsetX, t = m.t(x), view = currentView();
  let mode = 'move';
  if (!state.zoom) mode = 'select';  // whole night showing: drag out a range to look at
  else if (Math.abs(x - m.xa) < 7) mode = 'left';
  else if (Math.abs(x - m.xb) < 7) mode = 'right';
  else if (x < m.xa || x > m.xb) { const half = (view[1] - view[0]) / 2; setView(t - half, t + half); }
  ovDrag = { mode, x0: x, t0: t, view: currentView() };
  overview.setPointerCapture(e.pointerId);
  overview.style.cursor = mode === 'move' ? 'grabbing' : mode === 'select' ? 'crosshair' : 'ew-resize';
});
overview.addEventListener('pointermove', (e) => {
  const m = ovMap; if (!m) return;
  if (!ovDrag) {
    overview.style.cursor = !state.zoom ? 'crosshair' : Math.abs(e.offsetX - m.xa) < 7 || Math.abs(e.offsetX - m.xb) < 7 ? 'ew-resize' : 'grab';
    return;
  }
  const dt = ((e.offsetX - ovDrag.x0) / m.plotW) * m.total, [a, b] = ovDrag.view;
  if (ovDrag.mode === 'select') { if (Math.abs(e.offsetX - ovDrag.x0) > 3) { const t = m.t(e.offsetX); setView(Math.min(ovDrag.t0, t), Math.max(ovDrag.t0, t)); } }
  else if (ovDrag.mode === 'move') setView(a + dt, b + dt);
  else if (ovDrag.mode === 'left') setView(Math.min(a + dt, b - MIN_SPAN), b);
  else setView(a, Math.max(b + dt, a + MIN_SPAN));
});
function endOverviewDrag(e) {
  if (ovDrag?.mode === 'select' && Math.abs(e.offsetX - ovDrag.x0) <= 3 && ovMap) {
    const t = ovMap.t(e.offsetX); animateTo(t - 900, t + 900);  // a click on the whole-night strip zooms to half an hour there
  }
  ovDrag = null; overview.style.cursor = 'grab';
}
overview.addEventListener('pointerup', endOverviewDrag);
overview.addEventListener('pointercancel', () => { ovDrag = null; });
overview.addEventListener('wheel', (e) => {
  if (!ovMap) return;
  e.preventDefault();
  const view = currentView(), unit = e.deltaMode === 1 ? 33 : 1, d = ((Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY) * unit / ovMap.plotW) * ovMap.total;
  setView(view[0] + d, view[1] + d);
}, { passive: false });

// ---------- audio ----------
const audio = $('audio');
let segment = null, follow = true;
function audioFor(t) {
  const list = state.audio; let lo = 0, hi = list.length - 1, found = null;
  while (lo <= hi) { const m = (lo + hi) >> 1; if (list[m].start <= t) { found = m; lo = m + 1; } else hi = m - 1; }
  return found !== null && t < list[found].start + 61 ? { ...list[found], index: found } : null;
}
// Pull audio that is likely to be played into the server's cache ahead of time
// (the first fetch from the phone takes a second or two), one segment at a time.
const warmed = new Set(), warmQueue = []; let warming = false;
async function warmAudio(names) {
  for (const n of names) if (n && !warmed.has(n)) { warmed.add(n); warmQueue.push(n); }
  if (warming) return;
  warming = true;
  while (warmQueue.length) {
    try { await (await fetch('/api/audio/' + encodeURIComponent(warmQueue.shift()), { headers: { Range: 'bytes=0-0' }, priority: 'low' })).arrayBuffer(); }
    catch { /* best effort */ }
  }
  warming = false;
}
function warmAlertAudio() {
  const names = [];
  for (const r of currentRows) {
    const seg = audioFor(r.t - 10);
    if (seg) names.push(seg.name, state.audio[seg.index + 1]?.name);
  }
  warmAudio(names);
}
async function playAt(t, { follow: f = true } = {}) {
  const seg = audioFor(t); if (!seg) return;
  follow = f;
  $('player').style.display = 'flex';
  if (segment?.name !== seg.name) {
    segment = seg; $('playerTime').textContent = 'Loading…';
    audio.src = '/api/audio/' + encodeURIComponent(seg.name);
    warmAudio([state.audio[seg.index + 1]?.name]);
    try { await new Promise((ok, fail) => { audio.onloadedmetadata = ok; audio.onerror = () => fail(new Error('audio unavailable')); }); }
    catch (err) { $('playerTime').textContent = `Couldn't play: ${err.message}`; return; }
  }
  audio.currentTime = Math.max(0, t - seg.start);
  playhead = t;
  try { await audio.play(); } catch (err) { $('playerTime').textContent = `Couldn't play: ${err.message}`; }
  const [v0, v1] = currentView() ?? [0, 0];
  if (t < v0 || t > v1) animateTo(t - 20, t + 60);
  drawOverlay(); drawOverview();
}
audio.addEventListener('timeupdate', () => {
  if (!segment) return;
  playhead = segment.start + audio.currentTime;
  $('playerTime').textContent = fmtTime(playhead);
  // Keep the playhead in view while listening, unless the user is moving the chart.
  const view = currentView();
  if (follow && view && !drag && !anim && playhead > view[1] - (view[1] - view[0]) * 0.05 && playhead < view[1] + 30) {
    const s = view[1] - view[0]; setView(playhead - s * 0.2, playhead + s * 0.8);
  } else { drawOverlay(); drawOverview(); }
});
audio.addEventListener('ended', () => {
  const next = state.audio[segment?.index + 1];
  if (next && next.start - (segment.start + audio.duration) < 1.5) { segment = null; playAt(next.start, { follow }); }
});
audio.addEventListener('pause', () => { $('playerToggle').textContent = 'Play'; });
audio.addEventListener('play', () => { $('playerToggle').textContent = 'Pause'; follow = true; });
$('playerToggle').onclick = () => (audio.paused ? audio.play() : audio.pause());
$('playerBack').onclick = () => playhead !== null && playAt(playhead - 10);
$('playerFwd').onclick = () => playhead !== null && playAt(playhead + 10);
$('playerClose').onclick = () => { audio.pause(); playhead = null; segment = null; $('player').style.display = 'none'; drawOverlay(); drawOverview(); };

// ---------- compare settings ----------
let sweepGen = 0, sweepTimer = null;
function scheduleSweep(delay = 200) { clearTimeout(sweepTimer); sweepTimer = setTimeout(runSweep, delay); }
async function runSweep() {
  const g = ++sweepGen, stale = () => g !== sweepGen;
  const by = state.sweepBy, def = SWEEPS[by], ids = includedIds(), settings = { ...state.settings };
  const table = $('sweep');
  if (!ids.length) { table.innerHTML = '<tr><td class="empty">Load a night first.</td></tr>'; return; }
  table.classList.add('updating');
  const variant = (v) => ({ ...settings, asRecorded: false, [by]: v });
  await Promise.all(def.values.flatMap((v) => ids.map((id) => simulateNight(id, variant(v), 'low', stale))));
  if (stale()) return;
  table.classList.remove('updating');
  const rows = def.values.map((v) => ({ v, ...score(ids, variant(v)) }));
  const used = new Set(ids.map((id) => state.data.get(id).recordedSettings?.[by]).filter((x) => x !== undefined));
  const maxAlerts = Math.max(1, ...rows.map((r) => r.alerts));
  const anyLabels = rows.some((r) => r.cries || r.falseAlarms);
  const scale = (n) => (n / maxAlerts) * 100;
  table.innerHTML = `<thead><tr><th>${def.head}</th><th>Alerts</th><th class="bar"></th><th>Cries caught</th><th>False alarms</th><th>To label</th></tr></thead><tbody>${rows.map((r) => {
    const cur = !state.settings.asRecorded && r.v === state.settings[by];
    const tags = [cur ? 'current' : null, used.has(r.v) ? 'used' : null, by === 'alertDuration' && !APP_DURATIONS.includes(r.v) ? 'not in app' : null].filter(Boolean);
    return `<tr data-v="${r.v}" class="${cur ? 'current' : ''}"><td class="mono">${def.fmt(r.v)}${tags.map((t) => `<span class="tag">${t}</span>`).join('')}</td>
      <td class="mono">${r.alerts}</td>
      <td class="bar"><div class="barwrap">
        <span style="width:${scale(r.alerts - r.falseAlarms - r.unlabeled)}%;background:var(--cry)"></span>
        <span style="width:${scale(r.falseAlarms)}%;background:var(--noise)"></span>
        <span style="width:${scale(r.unlabeled)}%;background:var(--accent);opacity:.6"></span></div></td>
      <td class="mono" style="${r.cries && r.caught < r.cries ? 'color:var(--accent)' : ''}">${r.cries ? `${r.caught}/${r.cries}` : '–'}</td>
      <td class="mono">${anyLabels ? r.falseAlarms : '–'}</td><td class="mono">${r.unlabeled}</td></tr>`;
  }).join('')}</tbody>`;
  $('sweepNote').textContent = (anyLabels
    ? 'Bars: blue = alerts on a labelled cry, grey = labelled false alarms, orange = not labelled yet.'
    : 'Label alerts as Cry or Not a cry to count cries caught and false alarms at each setting.')
    + ` Covers ${ids.length} ticked night${ids.length === 1 ? '' : 's'}. Click a row to use that setting.`;
}
$('sweep').addEventListener('click', (ev) => {
  const tr = ev.target.closest('tbody tr[data-v]'); if (!tr) return;
  state.settings[state.sweepBy] = +tr.dataset.v; state.settings.asRecorded = false; touched(); syncControls(); refresh();
});
document.querySelectorAll('#sweepBy button').forEach((b) => {
  b.onclick = () => { state.sweepBy = b.dataset.v; store.set('sweepBy', state.sweepBy); syncControls(); scheduleSweep(0); };
});

// ---------- settings ----------
function touched() { store.set('settingsTouched', true); store.set('settings', state.settings); }
const RECORDED_KEYS = ['threshold', 'alertDuration', 'quietResetDuration', 'classifierThreshold'];
/// Replay with the phone's own settings: the sliders show the night's main ones.
function useRecorded() {
  const rec = state.data.get(state.focus)?.recordedSettings;
  Object.assign(state.settings, rec ?? {}, { asRecorded: true });
  store.set('settingsTouched', false); store.set('settings', state.settings);
}
function recordedSummary(data) {
  const ch = data?.settingsChanges ?? [];
  if (!ch.length) return 'This night has no recorded settings.';
  const fmt = (c) => `${c.threshold} dBFS · ${fmtDuration(c.alertDuration)} · ${c.quietResetDuration} s reset`;
  const parts = [`From ${fmtHM(ch[0].t)}: ${fmt(ch[0])}`];
  for (let k = 1; k < ch.length; k++) {
    const a = ch[k - 1], b = ch[k];
    if (a.threshold === b.threshold && a.alertDuration === b.alertDuration && a.quietResetDuration === b.quietResetDuration) continue;
    parts.push(`from ${fmtHM(b.t)}: ${fmt(b)}`);
  }
  return parts.join('; ') + '.';
}
function syncControls() {
  const s = state.settings;
  $('asRecorded').checked = s.asRecorded;
  $('controls').classList.toggle('as-recorded', s.asRecorded);
  $('recordedHint').textContent = s.asRecorded
    ? recordedSummary(state.data.get(state.focus)) + ' Move a slider to try your own.'
    : 'Replays each moment with the settings the phone used then.';
  $('threshold').step = state.appSteps ? 5 : 1;
  $('threshold').value = s.threshold; $('thresholdOut').textContent = `${s.threshold} dBFS`;
  $('thresholdHint').textContent = state.appSteps ? 'The app offers −60 to −10 dBFS in steps of 5.' : 'Steps of 1 dB. The app only offers steps of 5.';
  // The slider walks an index into the list of steps, so 5 s and 10 min are both reachable.
  const steps = durationSteps();
  $('duration').max = steps.length - 1; $('duration').value = nearestIndex(steps, s.alertDuration); $('durationOut').textContent = fmtDuration(s.alertDuration);
  document.querySelectorAll('#reset button').forEach((b) => b.classList.toggle('on', +b.dataset.v === s.quietResetDuration));
  $('appSteps').checked = state.appSteps;
  $('classifier').checked = s.classifierEnabled; $('classifierSub').hidden = !s.classifierEnabled;
  $('classThr').value = s.classifierThreshold; $('classThrOut').textContent = s.classifierThreshold.toFixed(2);
  $('gate').checked = s.gateEnabled; $('gateSub').hidden = !s.gateEnabled;
  $('gateMin').value = s.gateMin; $('gateMinOut').textContent = s.gateMin.toFixed(2);
  $('gateWin').value = s.gateWindow; $('gateWinOut').textContent = `${s.gateWindow} s`;
  $('fraction').value = s.requiredFraction; $('fractionOut').textContent = `${Math.round(s.requiredFraction * 100)}%`;
  document.querySelectorAll('#sweepBy button').forEach((b) => b.classList.toggle('on', b.dataset.v === state.sweepBy));
}
function bind(id, key, snap = (v) => v) {
  $(id).addEventListener('input', () => {
    const v = snap(Number($(id).value));
    if (state.settings[key] === v && !(state.settings.asRecorded && RECORDED_KEYS.includes(key))) return;
    state.settings[key] = v;
    if (RECORDED_KEYS.includes(key)) state.settings.asRecorded = false;
    touched(); syncControls(); refresh();
  });
}
const snapDuration = (v) => (state.appSteps ? APP_DURATIONS[nearestIndex(APP_DURATIONS, v)] : v);
bind('threshold', 'threshold');
bind('duration', 'alertDuration', (i) => durationSteps()[i]);
bind('classThr', 'classifierThreshold');
bind('gateMin', 'gateMin');
bind('gateWin', 'gateWindow');
bind('fraction', 'requiredFraction');
document.querySelectorAll('#reset button').forEach((b) => {
  b.onclick = () => { state.settings.quietResetDuration = +b.dataset.v; state.settings.asRecorded = false; touched(); syncControls(); refresh(); };
});
$('appSteps').onchange = () => {
  state.appSteps = $('appSteps').checked; store.set('appSteps', state.appSteps);
  if (state.appSteps) { state.settings.threshold = Math.round(state.settings.threshold / 5) * 5; state.settings.alertDuration = snapDuration(state.settings.alertDuration); }
  touched(); syncControls(); refresh();
};
$('classifier').onchange = () => { state.settings.classifierEnabled = $('classifier').checked; touched(); syncControls(); refresh(); };
$('gate').onchange = () => { state.settings.gateEnabled = $('gate').checked; touched(); syncControls(); refresh(); };
$('asRecorded').onchange = () => {
  if ($('asRecorded').checked) useRecorded();
  else { state.settings.asRecorded = false; touched(); }
  syncControls(); refresh();
};

// ---------- start ----------
async function start() {
  syncControls(); syncTabs();
  await loadLabels();
  try {
    const files = await (await api('/api/files')).json();
    state.sound = files.sound; state.audio = files.audio; state.offline = files.offline;
  } catch (err) { setStatus(`Can't reach the lab server: ${err.message}`, true); return; }
  state.nights = buildNights();
  if (!state.nights.length) { setStatus('No sound-analysis logs found on the phone or in the cache.', true); return; }
  if (!state.focus || !state.nights.some((n) => n.id === state.focus)) state.focus = state.nights[0].id;
  setStatus(statusLine(), state.offline);
  await focusNight(state.focus);
  // Let the night on screen finish its first replay before the workers start parsing others.
  await simulateNight(state.focus, state.settings, 'high', () => false);
  loadRecentInBackground();
}
start();
